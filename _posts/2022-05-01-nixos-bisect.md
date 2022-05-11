---
layout: post
title: Bisecting Linux with NixOS
hidden: true
---

## Bisecting the Linux Kernel with NixOS

### Introduction

Every bisect begins with some sort of story, and this one's no different.

This story centers around my Kubernetes cluster, which is run as a series of libvirt VMs, each running `k3s` via the [NixOS k3s module](https://github.com/NixOS/nixpkgs/blob/3fe4fe90a6f411a677c566cd030eea4b0359f8ef/nixos/modules/services/cluster/k3s/default.nix).

It won't matter quite yet, but since it will later, I'll also mention that the
host machine, on which I run these k3s VMs, isn't exactly the most up to date...

```
esk@prime-radiant ~ $ uptime -p
up 3 years, 5 weeks, 6 days, 10 hours, 43 minutes
esk@prime-radiant ~ $ uname -r
4.12.5-gentoo
```

<figure>
  <img src="/imgs/nixos-bisect/9-10-security-pros.png" width="500px" alt="9/10 security researchers recommend consulting a security professional if your uptime persists for more than 3 years. The 10th security researcher is actually a blackhat hacker"/>
</figure>

Yeah...

Normally, this cluster hums along happily, running various personal projects
and sites (including this one!). The VMs themselves are fairly up to date, and
updates have mostly been smooth. Speaking of, let's talk about the update that
leads to the main conflict in this story.

### A Bumpy Update

Since these VMs are all running NixOS, my rather naive process for updating them amounts to editing a [`nix flake`](https://nixos.wiki/wiki/Flakes) repo, and doing `ssh k8s-worker-$num "cd config && git pull && sudo nixos-rebuild --flake '.#k8s-worker-$num' switch"`. This isn't ideal, but it's worked so far!

In addition to the pod network changes mentioned above, I did a `nix flake
update` at some point since the last update. These VM's configurations are
small enough that, even tracking `nixos-unstable`, updating isn't scary.

So, what went wrong? Well, at first, nothing! The VMs all updated, my network
connectivity metric showed inter-pod communication was functioning, and the
stuff I hosted was all running with no complaints.

<i>3 hours later</i>

Oh no one of the nodes is unhealthy! Oh no, it's the single ingress node, so everything's offline.
Normally there would be multiple ingress nodes, but part of the update includes
shuffling around DNS entries, and I hadn't turned the "number of ingresses"
knob back up yet (oops)!

Fine, if I can't ssh in, hard-reset: `sudo virsh reset <node-name>`. Phew, at least everything came back up... surely that was just an errant kernel panic and I'll worry about it later.

<i>3 hours later</i>

Oh no one of the nodes is unhealthy! Oh no, it's the single ingress node!

What ensued was a frustrating debugging session where the network failed
seemingly with no exact pattern, and the longer I tried to observe the broken
state, the longer my stuff was offline.

For the sake of brevity, I'll skip to the answer: it turns out the `nix flake
update` above switched the default kernel version (from 5.10 to 5.15), and
reverting back to 5.10 (explicitly setting `boot.kernelPackages = pkgs.linuxPackages_5_10;`) got me back to a stable cluster.

After sleeping on this, I also realized that the ingress node going offline might mean that the network failure could be triggered by copying a lot of data. Spinning up a test VM and running `scp nixos.iso tmp-test-node:/dev/null` repeatedly showed that yes, indeed, after anywhere from 3-20GiB, the network would fail.

At this point I had two kernel versions, one good, one bad, and a repro. You
know what this means? Yup, git bisect time!

### Git bisecting NixOS VMs

The real repo for these VM's NixOS configurations isn't public (secrets are
hard, sorry!), so I've made an [approximation of the repo](https://github.com/euank/nixos-linux-bisect-post) for the purpose of the
blog post, which I'll use to demonstrate the rest of the git bisect process I took.

One of the great things about NixOS is how easy it is to go from a NixOS
configuration to a qemu VM image. As I mentioned, these VMs have thus far been
managed via the usual `nixos-rebuild switch --flake '.#k8s-worker'` mechanism,
but it seemed like it would be fewer steps to start with a fresh VM each time
for the bisect.

I started by thinning down the [nixos configuration](https://github.com/euank/nixos-linux-bisect-post/blob/465af387e8035042267d8fd0a5f2da2f043aff4f/repro/configuration.nix) a bit, and then [made that into a qemu image](https://github.com/euank/nixos-linux-bisect-post/commit/e743ac8c9acefe667906f8e65088b3a5b61a3c54):

```nix
# flake.nix
qemuImage = (import "${nixpkgs}/nixos/lib/make-disk-image.nix") {
  pkgs = pkgs;
  lib = pkgs.lib;

  diskSize = 8 * 1024;
  format = "qcow2";
  copyChannel = false;

  config =
    (evalConfig {
      inherit system;
      modules = [
        (import ./repro/configuration.nix {inherit pkgs inputs;})
      ];
    })
    .config;
};
```
<small>[source](https://github.com/euank/nixos-linux-bisect-post/blob/e743ac8c9acefe667906f8e65088b3a5b61a3c54/flake.nix#L31-L48)</small>

Nice, probably easier than the more common `debootstrap` flow! (Though I have seen some clean looking [debootstrap setups](https://github.com/google/syzkaller/blob/dc9e52595336dbe32f9a20f5da9f09cb8172cd21/tools/create-image.sh#L156-L192). It doesn't look nearly as reproducible though 😉.)

With that, we can run `nix build '.#qemuImage'`, and after a matter of minutes, get a
`./result/nixos.qcow2` for testing.

Unfortunately, I hit another small bump here: running the VM locally didn't
reproduce the issue, even after downgrading qemu and libvirt to the same
versions as my server. Was I dealing with a [heisenbug](https://en.wikipedia.org/wiki/Heisenbug)?
Ah, well, no matter. It still reproed on the remote host just fine.

Undeterred, I plowed forward to the final piece needed to start the bisect:
using a specific kernel commit for the NixOS configuration.

That, too, was fairly straightforward with NixOS's tooling:

```nix
# repro/configuration.nix
let
  commit = "2c85ebc57b3e1817b6ce1a6b703928e113a90442";
  kernel = pkgs.linuxPackages_custom {
    src = builtins.fetchTarball {
      url = "https://github.com/torvalds/linux/archive/${commit}.tar.gz";
      sha256 = "1znxp4v7ykfz4fghzjzhd5mj9pj5qpk88n7k7nbkr5x2n0xqfj6k";
    };
    version = "5.10.0";
    configfile = ./kconfig;
  };
in {
  boot.kernelPackages = kernel;
  # ...
}
```
<small>[source](https://github.com/euank/nixos-linux-bisect-post/blob/4dbbbd1b787ea694c6b9cb13a90cafcd1f671105/repro/configuration.nix#L8-L16)</small>

It was a little annoying that I had to specify a correct kernel version (or
else NixOS would refuse to build it, complaining "Error: modDirVersion x.y.z
specified in the Nix expression is wrong, it should be: 5.10.0"), but this
seemed like something easy enough to work with!

I made one final check that the current `master` branch of `torvalds/linux`
reproduced the bug (it did). With that, we finally get to our bisect script:

(saved as `bisect.sh` in a checkout of the linux kernel)
```bash
#!/usr/bin/env bash

set -ex

FLAKE_REPO=/path/to/flake/repo
serverHost="server-host"
# I pre-created a repro VM to work with using 'virt-install' which has a fixed
# IP. My IP address management setup is out of scope of this blog post, so we'll
# just have to accept it.
reproHost="repro-host"

# First, find the version
commit="$(git rev-parse HEAD)"
# nixpkgs.linuxPackages_custom _requires_ the kernel version string is correct
version="$(make kernelversion || exit 125)"

# figure out the nix hash
sha=$(nix-prefetch-url --unpack "https://github.com/torvalds/linux/archive/$commit.tar.gz")

# Write all this data to a place configuration.nix can find it

echo -n $commit > $FLAKE_REPO/repro/commit
echo -n $version > $FLAKE_REPO/repro/version
echo -n $sha > $FLAKE_REPO/repro/sha

cd $FLAKE_REPO
git add ./repro/{commit,version,sha}

time nix build '.#qemuImage' || exit 125

# Copy the image over
scp ./result/nixos.qcow2 $serverHost:

# Update the vm
ssh $serverHost sudo virsh destroy repro-vm || true

ssh $serverHost sudo sh -c '
  qemu-img convert ./nixos.qcow2 -O raw /tank/virts/disks/repro-vm.raw && \
  qemu-img resize -f raw /tank/virts/disks/repro-vm.raw 10G && \
  rm -f ./nixos.qcow2
' || exit 125

ssh $serverHost sudo virsh start repro-vm

# Wait for it to come up
for i in $(seq 1 60); do
  ssh -o ConnectTimeout=2 $reproHost true && break
  sleep 1
done

ssh $reproHost true || exit 125

# VM is up, verify we can copy the file many times with no issues. Note,
# typically takes about 30 seconds per copy unless the network failed
for i in $(seq 1 15); do
  if ! timeout 3m scp $HOME/Downloads/nixos-gnome-21.05.3208.8dd8bd8be74-x86_64-linux.iso $reproHost:/dev/null; then
    # Failed to copy, we got hung, this is a bad commit
    exit 1
  fi
done
```

This also needed some [small modifications](https://github.com/euank/nixos-linux-bisect-post/commit/2d85eada573ebf9fea34820162cbaf31535c69b3)
to `repro/configuration.nix` in order to read metadata about the linux commit
currently being tested.

From here, it was a simple matter of:

```
$ git bisect start
$ git bisect bad master
$ git bisect good v5.10
Bisecting: 59699 revisions left to test after this (roughly 16 steps)
$ git bisect run ./bisect.sh
```

and going to sleep.

<figure>
  <img width="300px" src="/imgs/sleepy-rp.jpg" alt="image of a sleeping red panda"/>
  <figcaption><i>zzz sleep interlude</i></figcaption>
</figure>

Let me tell you, the feeling of waking up and seeing the that a bisect you left running overnight not only completed, but seems to have found the right answer... it's great.

<details>

<summary>Commit message &amp; log</summary>


<pre>
8d622d21d24803408b256d96463eac4574dcf067 is the first bad commit
commit 8d622d21d24803408b256d96463eac4574dcf067
Date:   Tue Apr 13 01:19:16 2021 -0400

    virtio: fix up virtio_disable_cb

    virtio_disable_cb is currently a nop for split ring with event index.
    This is because it used to be always called from a callback when we know
    device won't trigger more events until we update the index.  However,
    now that we run with interrupts enabled a lot we also poll without a
    callback so that is different: disabling callbacks will help reduce the
    number of spurious interrupts.
    Further, if using event index with a packed ring, and if being called
    from a callback, we actually do disable interrupts which is unnecessary.

    Fix both issues by tracking whenever we get a callback. If that is
    the case disabling interrupts with event index can be a nop.
    If not the case disable interrupts. Note: with a split ring
    there's no explicit "no interrupts" value. For now we write
    a fixed value so our chance of triggering an interupt
    is 1/ring size. It's probably better to write something
    related to the last used index there to reduce the chance
    even further. For now I'm keeping it simple.

 drivers/virtio/virtio_ring.c | 26 +++++++++++++++++++++++++-
 1 file changed, 25 insertions(+), 1 deletion(-)
bisect found first bad commit

$ git bisect log
git bisect start
# bad: [3e732ebf7316ac83e8562db7e64cc68aec390a18] Merge tag 'for_linus' of git://git.kernel.org/pub/scm/linux/kernel/git/mst/vhost
git bisect bad 3e732ebf7316ac83e8562db7e64cc68aec390a18
# good: [2c85ebc57b3e1817b6ce1a6b703928e113a90442] Linux 5.10
git bisect good 2c85ebc57b3e1817b6ce1a6b703928e113a90442
# bad: [e083bbd6040f4efa5c13633fb4e460b919d69dae] Merge tag 'arm-dt-5.14' of git://git.kernel.org/pub/scm/linux/kernel/git/soc/soc
git bisect bad e083bbd6040f4efa5c13633fb4e460b919d69dae
# good: [5106efe6ed985d8d0b5dc5230a2ab2212810ee03] Merge git://git.kernel.org/pub/scm/linux/kernel/git/pablo/nf-next
git bisect good 5106efe6ed985d8d0b5dc5230a2ab2212810ee03
# good: [9ebd8118162b220d616d7e29b505dd64a90f75b6] Merge tag 'platform-drivers-x86-v5.13-2' of git://git.kernel.org/pub/scm/linux/kernel/git/pdx86/platform-drivers-x86
git bisect good 9ebd8118162b220d616d7e29b505dd64a90f75b6
# good: [9ce85ef2cb5c738754837a6937e120694cde33c9] io_uring: remove dead non-zero 'poll' check
git bisect good 9ce85ef2cb5c738754837a6937e120694cde33c9
# good: [a70bb580bfeaead9f685d4c28f7cd685c905d8c3] Merge tag 'devicetree-for-5.14' of git://git.kernel.org/pub/scm/linux/kernel/git/robh/linux
git bisect good a70bb580bfeaead9f685d4c28f7cd685c905d8c3
# good: [a16d8644bad461bb073b92e812080ea6715ddf2b] Merge tag 'staging-5.14-rc1' of git://git.kernel.org/pub/scm/linux/kernel/git/gregkh/staging
git bisect good a16d8644bad461bb073b92e812080ea6715ddf2b
# good: [8c1bfd746030a14435c9b60d08a81af61332089b] Merge tag 'pwm/for-5.14-rc1' of git://git.kernel.org/pub/scm/linux/kernel/git/thierry.reding/linux-pwm
git bisect good 8c1bfd746030a14435c9b60d08a81af61332089b
# good: [73d1774e0f6e3b6bee637b38ea0f2e722423f9fa] Merge tag 'v5.14-rockchip-dts64-1' of git://git.kernel.org/pub/scm/linux/kernel/git/mmind/linux-rockchip into arm/dt
git bisect good 73d1774e0f6e3b6bee637b38ea0f2e722423f9fa
# good: [1459718d7d79013a4814275c466e0b32da6a26bc] Merge tag 'powerpc-5.14-2' of git://git.kernel.org/pub/scm/linux/kernel/git/powerpc/linux
git bisect good 1459718d7d79013a4814275c466e0b32da6a26bc
# bad: [3de62951a5bee5dce5f4ffab8b7323ca9d3c7e1c] Merge tag 'sound-fix-5.14-rc1' of git://git.kernel.org/pub/scm/linux/kernel/git/tiwai/sound
git bisect bad 3de62951a5bee5dce5f4ffab8b7323ca9d3c7e1c
# bad: [db7b337709a15d33cc5e901d2ee35d3bb3e42b2f] virtio-mem: prioritize unplug from ZONE_MOVABLE in Big Block Mode
git bisect bad db7b337709a15d33cc5e901d2ee35d3bb3e42b2f
# good: [6f5312f801836e6af9bcbb0bdb44dc423e129206] vdpa/mlx5: Add support for running with virtio_vdpa
git bisect good 6f5312f801836e6af9bcbb0bdb44dc423e129206
# bad: [5bc72234f7c65830e60806dbb73ae76bacd8a061] virtio: use err label in __vring_new_virtqueue()
git bisect bad 5bc72234f7c65830e60806dbb73ae76bacd8a061
# bad: [e3aadf2e1614174dc81d52cbb9dabb77913b11c6] vdpa/mlx5: Clear vq ready indication upon device reset
git bisect bad e3aadf2e1614174dc81d52cbb9dabb77913b11c6
# bad: [8d622d21d24803408b256d96463eac4574dcf067] virtio: fix up virtio_disable_cb
git bisect bad 8d622d21d24803408b256d96463eac4574dcf067
# good: [22bc63c58e876cc359d0b1566dee3db8ecc16722] virtio_net: move txq wakeups under tx q lock
git bisect good 22bc63c58e876cc359d0b1566dee3db8ecc16722
# first bad commit: [8d622d21d24803408b256d96463eac4574dcf067] virtio: fix up virtio_disable_cb
</pre>

</details>

A [virtio commit](https://github.com/torvalds/linux/commit/8d622d21d24803408b256d96463eac4574dcf067)? Yup, that definitely sounds believable for network hangs in a VM using the `virtio_net` driver.

This was great, but it still didn't explain why I could only repro it on
that one machine, nor why no one had noticed and fixed it yet. The virtio
drivers do have a host component too (the vhost drivers), so perhaps the host
kernel version matters too?

Sure enough, running a VM with the above virtio commit on a different host
using a similarly old 4.12 kernel finally reproed it on a second machine....
meaning it was time for (you guessed it) *another git bisect*, this time of the
host kernel!

Now, initially I was thrilled at the prospect. The last bisect was easy thanks
to the power of NixOS! Unfortunately, this enthusiasm didn't last long.

### bisect 2: no VMs, old tools, and eventually no NixOS

This time, problems immediately reared their heads. First, just using the
4.12.5 kernel in NixOS's `pkgs.linuxPackages_custom` didn't work. It turns out
the first bisect went so smoothly in part because I was only working with
recent kernel versions, but going 4+ years back in time had some bumps.

```
$ nixos-rebuild build --flake '.#repro-host'
...
In file included from ../scripts/selinux/genheaders/genheaders.c:18:
../security/selinux/include/classmap.h:238:2: error: #error New address family defined, please update secclass_map.
  238 | #error New address family defined, please update secclass_map.
      |  ^~~~~
In file included from ../scripts/selinux/mdp/mdp.c:49:
../security/selinux/include/classmap.h:238:2: error: #error New address family defined, please update secclass_map.
  238 | #error New address family defined, please update secclass_map.
      |  ^~~~~
make[5]: *** [scripts/Makefile.host:107: scripts/selinux/genheaders/genheaders] Error 1
make[4]: *** [../scripts/Makefile.build:561: scripts/selinux/genheaders] Error 2
make[5]: *** [scripts/Makefile.host:107: scripts/selinux/mdp/mdp] Error 1
```

Okay, fine, it looks like selinux failed to compile. I guess we can just turn that off:

`sed -i 's|CONFIG_SECURITY_SELINUX=y|CONFIG_SECURITY_SELINUX=n|' repro-host/kconfig`.

```
$ nixos-rebuild build --flake '.#repro-host
Unsupported relocation type: R_X86_64_PLT32 (4)
make[4]: *** [../arch/x86/boot/compressed/Makefile:118: arch/x86/boot/compressed/vmlinux.relocs] Error 1
```

This one took _much_ longer to fail. A short google later let me
know that I needed an [older binutils](https://unix.stackexchange.com/questions/513921/how-to-get-around-r-x86-64-plt32-error-when-bisecting-the-linux-kernel).

I floundered around, doing everything from downgrading to NixOS 17.09, to running into bugs in `linuxPackages_custom` that had been fixed several years ago.
Eventually, the slow iteration speed of `linuxPackages_custom` got to me. It
has no support for incremental compilation (nor [`ccache` support](https://github.com/NixOS/nixpkgs/issues/153343)). Surely there's a
better way!

On many other distros, including Ubuntu, it's possible to just build a kernel
and use it, with incremental compilation working as one might expect. I
installed Ubuntu 18.04 (a version old enough I thought it would build the 4.12
kernel with no complaint), and tried to bisect from there.

This change from NixOS to Ubuntu instantly made the process less frustrating.
Running `make && sudo make modules_install && sudo make install` in a checkout
of the `4.12.x` kernel _just worked_, giving me incremental compilation and a
boot loader entry. I didn't even have to disable the initrd since `make install` built it for me, correctly and without any extra pain.

Switching to Ubuntu let me fairly quickly find [the commit](https://github.com/torvalds/linux/commit/8d65843c44269c21e95c98090d9bb4848d473853)
which fixed the bug for both older and newer guest kernel versions when applied
to the host.

This gave me enough information that I finally felt I could [report the issue upstream](https://lore.kernel.org/all/20220424230502.une24mt5sr65qcdk@Enkidudu/T/) without just wasting people's time.

I think this is a satisfying conclusion to this investigation. It turns out
that the 4.12 kernel has a bug in the `vhost` side of `virtio-ring`, and a
recent optimization to the guest side of `virtio-ring` fairly reliably triggers
that bug. This serves as a good forcing function to make me finally replace
that last Gentoo machine with NixOS, and it also let me learn a bit along the
way.

Speaking of, let's talk about a few learnings and notes.

### Learnings and Notes

#### NixOS might be the wrong tool for kernel bisects

<!-- rewrite this paragraph as a comparison between bisecting on gentoo and on
nix; the opening starts a little too broad for the content as it is now -->

My previous `git bisect` experience has mostly been on Gentoo, where I had a
hand-crafted minimal kernel config, and was able to boot an EFIStub kernel
directly with no initrd. NixOS, on the other hand, starts with a much thicker
kernel config, has numerous checks for various kernel modules, and seems to
require an initrd.

The ability to boot the kernel without an initrd enables a much more effective `git bisect flow` of just:

```
~/linux $ make
~/linux $ qemu-kvm -kernel arch/x86_64/boot/bzImage <other flags>
```

The iteration speed of the above setup is great, but NixOS's desire to also own
the kernel build process, its desire to use an initrd that matches the kernel,
and the general difficulty of building such an initrd, all conspire together to
make this more difficult on NixOS than the average distro.

Next time I need to do a kernel bisect, I expect I'll spend a little more time
upfront trying to reproduce my issue in a setup where my rootfs is a thin
buildroot, my kernel has a minimal config, and the vmlinuz binary is passed
from the host filesystem directly.

That said, the tradeoffs aren't too bad. It doesn't actually matter that much
whether a `git bisect run` takes 3 hours or 12 hours if you'll be AFK anyway,
and I had fun setting up the first bisect described above.

#### Some kernel debugging notes

This post focused on the kernel bisecting process, but my actual investigation
also included staring at gdb backtraces and trying to divine information from
`trace-cmd` output.

I didn't have a better place to include these links, but they were all great and deserve a shoutout :)

1. [`trace-cmd`](https://man7.org/linux/man-pages/man1/trace-cmd.1.html) is awesome.
    Check out `sudo trace-cmd record -p function_graph -g "vring_interrupt" -g "virtnet_poll" -n "printk"` + `trace-cmd report` if you want to see some fun call graphs
2. The [kernel GDB docs](https://01.org/linuxgraphics/gfx-docs/drm/dev-tools/gdb-kernel-debugging.html) are excellent.
3. [Dynamic debug](https://www.kernel.org/doc/html/v4.13/admin-guide/dynamic-debug-howto.html) in the linux kernel is awesome. `echo 'file virtio_ring.c +p' > /sys/kernel/debug/dynamic_debug/control` to immediately get debug logs in dmesg? Awesome.

I'll also give a shoutout to Red Hat's [virtio-ring](https://www.redhat.com/en/blog/virtqueues-and-virtio-ring-how-data-travels) posts. They're very helpful!

#### Possible NixOS Improvements

Let's talk about some of the differences between bisecting on Ubuntu and NixOS,
keeping an eye out for possible NixOS improvements.

##### `/sbin/installkernel`

I mentioned that `make install` for Ubuntu "just worked". How does that work? Surely the Linux `Makefile` doesn't know how to run Ubuntu's `update-grub` or such, right? Well, it turns out the linux `Makefile` calls a custom install script at [`/sbin/installkernel`](https://github.com/torvalds/linux/blob/5bfc75d92efd494db37f5c4c173d3639d4772966/arch/x86/boot/install.sh#L37) if present, and Ubuntu [includes such a script](https://manpages.ubuntu.com/manpages/bionic/man8/installkernel.8.html).

It's hard to imagine how NixOS could do the same thing; after all, a NixOS boot
entry specifies the entire system configuration, and it doesn't seem feasible
for NixOS to rebuild that configuration itself. It's possible to build a NixOS
system configuration using a flake on another machine, or to make impure
references to files that may not even exist anymore.

Providing a mechanism like this in NixOS would probably require having some
sort of "impure" boot entry, where a kernel and initrd are used which don't
"match" the NixOS configuration they boot.

I don't think this mechanism should be a commonly used thing, but I think it
would be neat to have for cases like this one.

##### Externally built kernel

Currently, NixOS provides `linuxPackages_custom` to build a custom kernel
version. I couldn't find any equivalent mechanism to point
`boot.kernelpackages` at a pre-built kernel and its modules. This mechanism
would have made incremental compilation much easier, especially when adding
printk debugging statements and rebuilding.

It doesn't seem to me like there's any fundamental reason that prebuilt
binaries can't be plugged in as inputs here, and it's simply a matter of
someone wiring it up.

##### Booting with no initrd

Skipping the initrd is one way to somewhat speed up iteration times. Most linux
distros allow you to not have an initrd at all. It's a necessity in many setups
(i.e. to luks decrypt the partition containing your rootfs, or to do LVM
setup), but most distros can be configured in such a way that you don't need
it. An Ubuntu installation without encryption or luks will happily boot an
EFISTUB kernel without an initrd.

NixOS, on the other hand, has no documented way to boot without an initrd that
I know of.

This seems to me like it should be feasible to add as a supported option for
NixOS.

### Final Thoughts

Git bisecting is fun. I highly recommend using [`git bisect run`](https://lwn.net/Articles/317154/) whenever possible.

It's a testament to the quality of the linux repository that I had zero skips in my git bisects of it (i.e. all commits my bisect tried built and at least booted).

Oh, also, update your machines frequently. Updating that VM host any time in
the past 3 years would have saved me hours of sleep.
