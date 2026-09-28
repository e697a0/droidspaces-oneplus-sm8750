# Bundled AnyKernel3 tools (AArch64)

Upstream [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) ships its
`tools/` binaries built for **32-bit ARM**.  The target platform of this project
is Qualcomm **SM8750** ("sun", Snapdragon 8 Elite), whose Oryon cores are
**64-bit only**:

```
ro.product.cpu.abilist   = arm64-v8a
ro.product.cpu.abilist32 = (empty)
```

Running any of the upstream 32-bit tools there fails immediately with
`Exec format error`, which AnyKernel3 surfaces as
`Busybox setup failed. Aborting...`.  This directory therefore carries the
same tool set rebuilt for **AArch64**, and `scripts/package-anykernel.sh`
overlays it on top of the cloned AnyKernel3 tree.

All seven binaries were verified to execute on an SM8750 device.

## Provenance

The AArch64 builds were taken from
[Draklyfg/oneplus-sm8750-kernel-pro-build](https://github.com/Draklyfg/oneplus-sm8750-kernel-pro-build)
`ak3/tools/`, which is a repack of the same AnyKernel3 tool set for this device
family (that project is verified on real SM8750 hardware).

## Licences (identical to what AnyKernel3 itself declares)

| Binary | Licence | Upstream |
|---|---|---|
| `busybox` | GPLv2 | https://github.com/osm0sis/android-busybox-ndk (this build: BusyBox v1.36.1.1 topjohnwu) |
| `magiskboot`, `magiskpolicy` | GPLv3+ | https://github.com/topjohnwu/Magisk |
| `lptools_static` | Apache-2.0 | https://github.com/phhusson/vendor_lptools |
| `fec` | Apache-2.0 | https://android.googlesource.com/platform/system/extras/+/master/verity/fec/ |
| `snapshotupdater_static` | Apache-2.0 | https://github.com/capntrips/SnapshotUpdater |
| `httools_static` | MIT | https://github.com/capntrips |

These are separate programs aggregated into the flashable package; the MIT /
Apache-2.0 / GPL terms above apply to each binary individually.  The full
AnyKernel3 `LICENSE` file is shipped inside every zip we produce, exactly as
upstream does.  Corresponding source for the GPL components is available at the
links above (and, as upstream AnyKernel3 states, on request).
