/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _DRIVERS_NET_IMQ_A16_XFRM_COMPAT_H
#define _DRIVERS_NET_IMQ_A16_XFRM_COMPAT_H

#include <linux/netdevice.h>

/*
 * Android-16 donor commit ae25507f3 adds an @again out-parameter to
 * validate_xmit_skb_list() so asynchronous XFRM offload can ask the qdisc to
 * retry an skb later.  OPPO's vendor IMQ caller predates that API.
 *
 * Keep the source call site untouched but reproduce sch_direct_xmit()'s new
 * semantics locally: validate with @again, and if XFRM requests a retry put
 * the skb/list back in q->gso_skb under the qdisc root lock and schedule it.
 * The macro is object-local via CFLAGS_imq.o, so no other networking caller is
 * affected.
 */
#undef validate_xmit_skb_list
#define validate_xmit_skb_list(skb, dev) (validate_xmit_skb_list)((skb), (dev))

#endif /* _DRIVERS_NET_IMQ_A16_XFRM_COMPAT_H */
