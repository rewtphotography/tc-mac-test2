"""Converts BiRefNet_HR to Core ML for TrainCull (docs/specs/masking-spec-v2.md, section 3.2).

BiRefNet uses deformable convolution, which Core ML has no operation for. It is replaced
here by the same arithmetic written with bilinear resampling, which Core ML does have, and
the replacement is checked against the original before anything is converted.

  convert_birefnet.py check                      the replacement against torchvision's own
  convert_birefnet.py convert <out.mlpackage>    parity on the real model, then the conversion

Runs on Linux or a Mac with torch, torchvision, transformers and coremltools. Nothing from
here ships in the app except the converted model.
"""
import sys

import numpy as np
import torch
import torch.nn.functional as F

SIDE = 2048


def deform_conv2d_gs(input, offset, weight, bias=None, stride=(1, 1), padding=(0, 0), dilation=(1, 1), mask=None):
    """torchvision.ops.deform_conv2d for one offset group, by resampling: for each position of
    the kernel, the input is sampled where the offsets say, weighted, and summed."""
    pair = lambda v: (v, v) if isinstance(v, int) else tuple(v)
    (sh, sw), (ph, pw), (dh, dw) = pair(stride), pair(padding), pair(dilation)
    n, _, h, w = input.shape
    cout, _, kh, kw = weight.shape
    ho = (h + 2 * ph - dh * (kh - 1) - 1) // sh + 1
    wo = (w + 2 * pw - dw * (kw - 1) - 1) // sw + 1
    ys = torch.arange(ho, device=input.device, dtype=input.dtype) * sh - ph
    xs = torch.arange(wo, device=input.device, dtype=input.dtype) * sw - pw
    gy, gx = torch.meshgrid(ys, xs, indexing="ij")
    out = None
    k = 0
    for i in range(kh):
        for j in range(kw):
            py = gy + i * dh + offset[:, 2 * k]
            px = gx + j * dw + offset[:, 2 * k + 1]
            grid = torch.stack(((px + 0.5) / w * 2 - 1, (py + 0.5) / h * 2 - 1), dim=-1)
            s = F.grid_sample(input, grid, mode="bilinear", padding_mode="zeros", align_corners=False)
            if mask is not None:
                s = s * mask[:, k:k + 1]
            term = F.conv2d(s, weight[:, :, i:i + 1, j:j + 1])
            out = term if out is None else out + term
            k += 1
    return out if bias is None else out + bias.view(1, -1, 1, 1)


def check():
    from torchvision.ops import deform_conv2d
    torch.manual_seed(1)
    worst = 0.0
    for kernel, pad, stride in ((1, 0, 1), (3, 1, 1), (7, 3, 1), (3, 1, 2)):
        x = torch.randn(2, 6, 23, 31)
        weight = torch.randn(5, 6, kernel, kernel)
        bias = torch.randn(5)
        probe = F.conv2d(x, weight, stride=stride, padding=pad)
        offset = torch.randn(2, 2 * kernel * kernel, probe.shape[2], probe.shape[3]) * 2.5
        mask = torch.rand(2, kernel * kernel, probe.shape[2], probe.shape[3]) * 2
        a = deform_conv2d(x, offset, weight, bias, stride=stride, padding=pad, mask=mask)
        b = deform_conv2d_gs(x, offset, weight, bias, stride=stride, padding=pad, mask=mask)
        worst = max(worst, float((a - b).abs().max() / a.abs().max()))
    print(f"deformable convolution replacement: worst relative difference {worst:.2e}")
    assert worst < 1e-4, "the replacement does not match"


class BaseNet(torch.nn.Module):
    """The model with its input scaling built in: red, green and blue from 0 to 1 go in, a
    soft mask from 0 to 1 comes out."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        y = self.model((x - self.mean) / self.std)
        y = y[-1] if isinstance(y, (list, tuple)) else y
        return torch.sigmoid(y)


def picture(side):
    """A made-up picture with something in it: a textured disc on a gradient."""
    yy, xx = np.mgrid[0:side, 0:side].astype(np.float32) / side
    disc = ((xx - 0.55) ** 2 + (yy - 0.45) ** 2) < 0.07
    rgb = np.stack([0.2 + 0.5 * xx, 0.3 + 0.2 * yy, 0.5 - 0.3 * xx], 0)
    rgb[:, disc] = np.stack([0.8 + 0.1 * np.sin(40 * xx), 0.5 + 0.0 * xx, 0.2 + 0.1 * np.cos(30 * yy)], 0)[:, disc]
    return torch.from_numpy(rgb[None].astype(np.float32))


def patch_coremltools():
    """coremltools trips over `int(...)` of a one-element array, which the Swin backbone does
    when it works out window sizes. This is the usual replacement for that one operation."""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

    @register_torch_op(torch_alias=["int"], override=True)
    def _int(context, node):
        x = _get_inputs(context, node, expected=1)[0]
        if x.val is not None:
            res = mb.const(val=np.int32(np.array(x.val).reshape(-1)[0]), name=node.name)
        else:
            if len(x.shape) > 0:
                x = mb.squeeze(x=x)
            res = mb.cast(x=x, dtype="int32", name=node.name)
        context.add(res)


def convert(out, side=SIDE):
    import os
    import coremltools as ct
    patch_coremltools()
    kept = out + ".traced.pt"
    if os.path.exists(kept):
        finish(ct, torch.jit.load(kept), out, side)
        return
    from transformers import AutoModelForImageSegmentation
    model = AutoModelForImageSegmentation.from_pretrained("ZhengPeng7/BiRefNet_HR", trust_remote_code=True).eval().float()
    net = BaseNet(model).eval()
    x = picture(side)
    with torch.no_grad():
        original = net(x)
    # Swap the operation in the module that defines the model, then check nothing changed.
    module = sys.modules[type(model).__module__]
    assert hasattr(module, "deform_conv2d"), "BiRefNet's code no longer uses deform_conv2d by that name"
    module.deform_conv2d = deform_conv2d_gs
    with torch.no_grad():
        patched = net(x)
    diff = float((original - patched).abs().max())
    a, b = original >= 0.5, patched >= 0.5
    iou = float((a & b).sum()) / max(float((a | b).sum()), 1.0)
    print(f"original against patched: largest difference {diff:.2e}, agreement {iou:.5f}, subject area {float(a.float().mean()):.3f}")
    assert diff < 1e-3 and iou > 0.999, "the patched model does not match the original"
    del original, patched
    import gc
    gc.collect()
    print("tracing", flush=True)
    with torch.no_grad():
        # No second run to double-check the trace: at this size it would need twice the memory,
        # and the conversion is checked against the original afterwards anyway.
        traced = torch.jit.trace(net, x, strict=False, check_trace=False)
    if os.environ.get("KEEP_TRACE"):
        traced.save(kept)
    del model, net
    gc.collect()
    finish(ct, traced, out, side)


def finish(ct, traced, out, side):
    print("converting", flush=True)
    mlmodel = ct.convert(
        traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14,
        inputs=[ct.ImageType(name="image", shape=(1, 3, side, side), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="mask")])
    mlmodel.short_description = f"BiRefNet_HR (MIT), {side}x{side}, deformable convolution rewritten for Core ML"
    mlmodel.save(out)
    print("saved", out)


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check()
    else:
        check()
        convert(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else SIDE)
