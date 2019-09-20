/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "video/out/gpu/context.h"
#include "osdep/macOS_swift.h"

//#import <MoltenVK/mvk_vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"

struct priv {
    struct mpvk_ctx vk;
    MacosCommon *vo_macos;
};


static void macos_vk_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;

    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);
    [p->vo_macos uninit:ctx->vo];
}

static bool macos_vk_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    struct mpvk_ctx *vk = &p->vk;
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (!mpvk_init(vk, ctx, VK_MVK_MACOS_SURFACE_EXTENSION_NAME))
        goto error;

    p->vo_macos = [[MacosCommon alloc] init:ctx->vo];
    if (!p->vo_macos)
        goto error;

    VkMacOSSurfaceCreateInfoMVK macos_info = {
        .sType = VK_STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK,
        .pNext = NULL,
        .flags = 0,
        .pView = p->vo_macos.video,
    };

    VkInstance inst = vk->vkinst->instance;
    VkResult res = vkCreateMacOSSurfaceMVK(inst, &macos_info, NULL, &vk->surface);
    if (res != VK_SUCCESS) {
        MP_MSG(ctx, msgl, "Failed creating macos surface\n");
        goto error;
    }

    //VK_PRESENT_MODE_FIFO_KHR
    if (!ra_vk_ctx_init(ctx, vk, VK_PRESENT_MODE_IMMEDIATE_KHR))
        goto error;

    /*
    ra_add_native_resource(ctx->ra, "wl", ctx->vo->wl->display);*/

    return true;
error:
    if (p->vo_macos)
        [p->vo_macos uninit:ctx->vo];
    return false;
}

static bool resize(struct ra_ctx *ctx)
{
    return ra_vk_ctx_resize(ctx, 1024, 574);

    /*struct vo_macos_state *wl = ctx->vo->wl;

    MP_VERBOSE(wl, "Handling resize on the vk side\n");

    const int32_t width = wl->scaling*mp_rect_w(wl->geometry);
    const int32_t height = wl->scaling*mp_rect_h(wl->geometry);

    wl_surface_set_buffer_scale(wl->surface, wl->scaling);
    return ra_vk_ctx_resize(ctx, width, height);*/
}

static bool macos_vk_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (![p->vo_macos config:ctx->vo])
        return false;
    return true;
}

static int macos_vk_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    int ret = [p->vo_macos control:ctx->vo events:events request:request arg:arg];

    if (*events & VO_EVENT_RESIZE) {
        if (!resize(ctx))
            return VO_ERROR;
    }

    return ret;
}

static void macos_vk_wakeup(struct ra_ctx *ctx)
{
    //printf("macos_vk_wakeup");
    //vo_macos_wakeup(ctx->vo);
}

static void macos_vk_wait_events(struct ra_ctx *ctx, int64_t until_time_us)
{
    //printf("macos_vk_wait_events");
    //vo_macos_wait_events(ctx->vo, until_time_us);
}

const struct ra_ctx_fns ra_ctx_vulkan_macos = {
    .type           = "vulkan",
    .name           = "macosvk",
    .reconfig       = macos_vk_reconfig,
    .control        = macos_vk_control,
    .wakeup         = macos_vk_wakeup,
    .wait_events    = macos_vk_wait_events,
    .init           = macos_vk_init,
    .uninit         = macos_vk_uninit,
};