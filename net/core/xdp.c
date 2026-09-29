// SPDX-License-Identifier: GPL-2.0
/*
 * net/core/xdp.c
 *
 * Generic XDP support routines.
 */

#include <linux/export.h>
#include <net/xdp.h>
#include <linux/netdevice.h>
#include <linux/slab.h>

void xdp_rxq_info_unreg(struct xdp_rxq_info *xdp_rxq)
{
	xdp_rxq->reg_state = 0;
	xdp_rxq->dev = NULL;
}
EXPORT_SYMBOL_GPL(xdp_rxq_info_unreg);

int xdp_rxq_info_reg(struct xdp_rxq_info *xdp_rxq,
		     struct net_device *dev, u32 queue_index)
{
	if (!dev)
		return -ENODEV;
	memset(xdp_rxq, 0, sizeof(*xdp_rxq));
	xdp_rxq->dev = dev;
	xdp_rxq->queue_index = queue_index;
	xdp_rxq->reg_state = 1;
	return 0;
}
EXPORT_SYMBOL_GPL(xdp_rxq_info_reg);

bool xdp_rxq_info_is_reg(struct xdp_rxq_info *xdp_rxq)
{
	return (xdp_rxq->reg_state != 0);
}
EXPORT_SYMBOL_GPL(xdp_rxq_info_is_reg);

int xdp_rxq_info_reg_mem_model(struct xdp_rxq_info *xdp_rxq,
			       enum xdp_mem_type type, void *allocator)
{
	return 0;
}
EXPORT_SYMBOL_GPL(xdp_rxq_info_reg_mem_model);
