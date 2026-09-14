// SPDX-License-Identifier: GPL-2.0
/*
 * Isolated 4.14 backport of BPF queue/stack maps.
 * Adapted from Linux 4.20 without replacing kernel/bpf/.
 */
#include <linux/bpf.h>
#include <linux/slab.h>
#include <linux/capability.h>
#include <linux/spinlock.h>
#include <linux/filter.h>
#include <linux/mm.h>

#define QUEUE_STACK_CREATE_FLAG_MASK \
	(BPF_F_NUMA_NODE | BPF_F_RDONLY | BPF_F_WRONLY)

struct bpf_queue_stack {
	struct bpf_map map;
	raw_spinlock_t lock;
	u32 head, tail;
	u32 size; /* max_entries + 1 */
	char elements[0] __aligned(8);
};

static struct bpf_queue_stack *bpf_queue_stack(struct bpf_map *map)
{
	return container_of(map, struct bpf_queue_stack, map);
}

static bool queue_stack_map_is_empty(struct bpf_queue_stack *qs)
{
	return qs->head == qs->tail;
}

static bool queue_stack_map_is_full(struct bpf_queue_stack *qs)
{
	u32 head = qs->head + 1;

	if (unlikely(head >= qs->size))
		head = 0;
	return head == qs->tail;
}

static struct bpf_map *queue_stack_map_alloc(union bpf_attr *attr)
{
	int ret, numa_node = bpf_map_attr_numa_node(attr);
	struct bpf_queue_stack *qs;
	u64 size, queue_size, cost;

	if (!capable(CAP_SYS_ADMIN))
		return ERR_PTR(-EPERM);
	if (attr->max_entries == 0 || attr->key_size != 0 ||
	    attr->value_size == 0 ||
	    attr->map_flags & ~QUEUE_STACK_CREATE_FLAG_MASK)
		return ERR_PTR(-EINVAL);
	if (attr->value_size > KMALLOC_MAX_SIZE)
		return ERR_PTR(-E2BIG);

	size = (u64)attr->max_entries + 1;
	cost = queue_size = sizeof(*qs) + size * attr->value_size;
	if (cost >= U32_MAX - PAGE_SIZE)
		return ERR_PTR(-E2BIG);
	cost = round_up(cost, PAGE_SIZE) >> PAGE_SHIFT;

	ret = bpf_map_precharge_memlock(cost);
	if (ret < 0)
		return ERR_PTR(ret);

	qs = bpf_map_area_alloc(queue_size, numa_node);
	if (!qs)
		return ERR_PTR(-ENOMEM);

	qs->map.map_type = attr->map_type;
	qs->map.key_size = attr->key_size;
	qs->map.value_size = attr->value_size;
	qs->map.max_entries = attr->max_entries;
	qs->map.map_flags = attr->map_flags;
	qs->map.numa_node = numa_node;
	qs->map.pages = cost;
	qs->size = size;
	raw_spin_lock_init(&qs->lock);
	return &qs->map;
}

static void queue_stack_map_free(struct bpf_map *map)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);

	synchronize_rcu();
	bpf_map_area_free(qs);
}

static int queue_stack_map_push_elem(struct bpf_map *map, void *value, u64 flags)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);
	unsigned long irq_flags;
	bool replace = (flags & BPF_EXIST);
	int err = 0;
	void *dst;

	if ((flags & BPF_NOEXIST) || flags > BPF_EXIST)
		return -EINVAL;

	raw_spin_lock_irqsave(&qs->lock, irq_flags);
	if (queue_stack_map_is_full(qs)) {
		if (!replace) {
			err = -E2BIG;
			goto out;
		}
		if (unlikely(++qs->tail >= qs->size))
			qs->tail = 0;
	}
	dst = &qs->elements[qs->head * qs->map.value_size];
	memcpy(dst, value, qs->map.value_size);
	if (unlikely(++qs->head >= qs->size))
		qs->head = 0;
out:
	raw_spin_unlock_irqrestore(&qs->lock, irq_flags);
	return err;
}

static int queue_map_pop_elem(struct bpf_map *map, void *value)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);
	unsigned long irq_flags;
	int err = 0;
	void *src;

	raw_spin_lock_irqsave(&qs->lock, irq_flags);
	if (queue_stack_map_is_empty(qs)) {
		err = -ENOENT;
		goto out;
	}
	src = &qs->elements[qs->tail * qs->map.value_size];
	memcpy(value, src, qs->map.value_size);
	if (unlikely(++qs->tail >= qs->size))
		qs->tail = 0;
out:
	raw_spin_unlock_irqrestore(&qs->lock, irq_flags);
	return err;
}

static int queue_map_peek_elem(struct bpf_map *map, void *value)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);
	unsigned long irq_flags;
	int err = 0;
	void *src;

	raw_spin_lock_irqsave(&qs->lock, irq_flags);
	if (queue_stack_map_is_empty(qs)) {
		err = -ENOENT;
		goto out;
	}
	src = &qs->elements[qs->tail * qs->map.value_size];
	memcpy(value, src, qs->map.value_size);
out:
	raw_spin_unlock_irqrestore(&qs->lock, irq_flags);
	return err;
}

static int stack_map_pop_elem(struct bpf_map *map, void *value)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);
	unsigned long irq_flags;
	int err = 0;
	void *src;

	raw_spin_lock_irqsave(&qs->lock, irq_flags);
	if (queue_stack_map_is_empty(qs)) {
		err = -ENOENT;
		goto out;
	}
	if (qs->head == 0)
		qs->head = qs->size - 1;
	else
		qs->head--;
	src = &qs->elements[qs->head * qs->map.value_size];
	memcpy(value, src, qs->map.value_size);
out:
	raw_spin_unlock_irqrestore(&qs->lock, irq_flags);
	return err;
}

static int stack_map_peek_elem(struct bpf_map *map, void *value)
{
	struct bpf_queue_stack *qs = bpf_queue_stack(map);
	unsigned long irq_flags;
	u32 head;
	int err = 0;
	void *src;

	raw_spin_lock_irqsave(&qs->lock, irq_flags);
	if (queue_stack_map_is_empty(qs)) {
		err = -ENOENT;
		goto out;
	}
	head = qs->head == 0 ? qs->size - 1 : qs->head - 1;
	src = &qs->elements[head * qs->map.value_size];
	memcpy(value, src, qs->map.value_size);
out:
	raw_spin_unlock_irqrestore(&qs->lock, irq_flags);
	return err;
}

static void *queue_stack_map_lookup_elem(struct bpf_map *map, void *key)
{
	return NULL;
}

static int queue_stack_map_update_elem(struct bpf_map *map, void *key,
				       void *value, u64 flags)
{
	return -EINVAL;
}

static int queue_stack_map_delete_elem(struct bpf_map *map, void *key)
{
	return -EINVAL;
}

static int queue_stack_map_get_next_key(struct bpf_map *map, void *key,
					void *next_key)
{
	return -EINVAL;
}

const struct bpf_map_ops queue_map_ops = {
	.map_alloc = queue_stack_map_alloc,
	.map_free = queue_stack_map_free,
	.map_lookup_elem = queue_stack_map_lookup_elem,
	.map_update_elem = queue_stack_map_update_elem,
	.map_delete_elem = queue_stack_map_delete_elem,
	.map_push_elem = queue_stack_map_push_elem,
	.map_pop_elem = queue_map_pop_elem,
	.map_peek_elem = queue_map_peek_elem,
	.map_get_next_key = queue_stack_map_get_next_key,
};

const struct bpf_map_ops stack_map_ops = {
	.map_alloc = queue_stack_map_alloc,
	.map_free = queue_stack_map_free,
	.map_lookup_elem = queue_stack_map_lookup_elem,
	.map_update_elem = queue_stack_map_update_elem,
	.map_delete_elem = queue_stack_map_delete_elem,
	.map_push_elem = queue_stack_map_push_elem,
	.map_pop_elem = stack_map_pop_elem,
	.map_peek_elem = stack_map_peek_elem,
	.map_get_next_key = queue_stack_map_get_next_key,
};
