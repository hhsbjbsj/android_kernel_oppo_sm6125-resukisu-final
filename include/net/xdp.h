/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_NET_XDP_H__
#define _LINUX_NET_XDP_H__

#include <linux/types.h>

struct net_device;

enum xdp_mem_type {
	MEM_TYPE_PAGE_SHARED = 0,
	MEM_TYPE_PAGE_ORDER0,
	MEM_TYPE_PAGE_POOL,
	MEM_TYPE_ZERO_COPY,
	MEM_TYPE_MAX,
};

struct xdp_mem_info {
	u32 type;
	u32 id;
};

struct xdp_rxq_info {
	struct net_device *dev;
	u32 queue_index;
	u32 reg_state;
	struct xdp_mem_info mem;
} ____cacheline_aligned;

int xdp_rxq_info_reg(struct xdp_rxq_info *xdp_rxq,
		     struct net_device *dev, u32 queue_index);
void xdp_rxq_info_unreg(struct xdp_rxq_info *xdp_rxq);
bool xdp_rxq_info_is_reg(struct xdp_rxq_info *xdp_rxq);
int xdp_rxq_info_reg_mem_model(struct xdp_rxq_info *xdp_rxq,
			       enum xdp_mem_type type, void *allocator);

#endif /* _LINUX_NET_XDP_H__ */
