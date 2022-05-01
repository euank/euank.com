---
layout: post
title: Bisecting Linux with NixOS
---

### Background

Every bisect begins with some sort of story, and this one's no different.

I run a Kubernetes cluster as a series of libvirt VMs, each running `k3s` via the [NixOS k3s module](https://github.com/NixOS/nixpkgs/blob/3fe4fe90a6f411a677c566cd030eea4b0359f8ef/nixos/modules/services/cluster/k3s/default.nix).

It won't matter quite yet, but since it will later, I'll also mention that the
host machine here isn't exactly the most up to date...

```
esk@prime-radiant ~ $ uptime -p
up 3 years, 5 weeks, 6 days, 10 hours, 43 minutes
esk@prime-radiant ~ $ uname -r
4.12.5-gentoo
```

Yeah.... Anyway, back to the more immediately relevant details.

I updated each VM's configuration, including the linux kernel version (to
5.17), all seemed well, and I carried on... until several hours later one VM's
network's stopped working, only coming back with a hard reboot (`virsh reset`).
Over the next day, VM's networks suffered similar failures left and right. I'll
skip some of the flailing around reverting other config changes, and jump
straight to "it was the kernel upgrade, reverting back (to 5.10) worked around
the issue".

In the course of this, I also realized copying around 3-20GiBs of data
reproduced it fairly reliably, which was incredibly helpful for figuring out
what did or didn't fix it.

At this point I had two kernel versions, one good, one bad, and a sorta okay
repro. You know what this means? Yup, git bisect time!

#### Git bisecting NixOS VMs

The real repo for these VM's NixOS configurations isn't public (secrets are
hard, sorry!), so I've made an approximation of the repo for the purpose of the
blog post, which I'll use to demonstrate the rest of the git bisect process.

One of the great things about NixOS is how easy it is to go from a NixOS
configuration to a qemu VM image. So far, these VMs have been managed via the
usual `nixos-rebuild switch --flake '.#k8s-worker'` mechanism, but it seemed
like it would be fewer steps to start with a fresh VM each time for the bisect.

I started by thinning down the [nixos configuration](TODO) a bit, and then made that into a qemu image:

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

Nice and simple!

That let me run `nix build '.#qemuImage'`, and after a matter of minutes, get a
`./result/nixos.qcow2` for testing.

Unfortunately, I hit a small bump here: running the VM locally didn't reproduce
the issue, even after downgrading qemu and libvirt to the same versions as my
server. Ah, well, no matter. It still reproduced on the remote host.

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

It was a little annoying that I had to specify a correct kernel version (or
else NixOS would refuse to build it, complaining "Error: modDirVersion x.y.z
specified in the Nix expression is wrong, it should be: 5.10.0"), but this
seemed like something easy enough to work with!

I made one final check that the current `master` branch of `torvalds/linux`
reproduced the bug (it did). With that, we finally get to our bisect script:

(saved as 'bisect.sh' in a checkout of the linux kernel)
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

ssh $serverHost sudo sh -c "'qemu-img convert ./nixos.qcow2 -O raw /tank/virts/disks/repro-vm.raw && qemu-img resize -f raw /tank/virts/disks/repro-vm.raw 10G && rm -f ./nixos.qcow2'" || exit 125

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

This also needed some small modifications to `repro/configuration.nix`:

```nix
# repro/configuration.nix
let
  commit = builtins.readFile ./commit;
  sha = builtins.readFile ./sha;
  kversion = builtins.readFile ./version;

  kernel = pkgs.linuxPackages_custom {
    src = builtins.fetchTarball {
      url = "https://github.com/euank/linux/archive/${commit}.tar.gz";
      sha256 = sha;
    };
    version = kversion;
    configfile = ./kconfig;
  };
# ...
```

From here, it was a simple matter of:

```
$ git bisect start
$ git bisect bad master
$ git bisect good v5.10
Bisecting: 59699 revisions left to test after this (roughly 16 steps)
$ git bisect run ./bisect.sh
```

and going to sleep.

----

Let me tell you, the feeling of waking up and seeing the that a bisect you left running overnight not only completed, but seems to have found the right answer... it's great.

The next morning, it had my bad commit, and it looked very believable:

```
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
```

A [virtio commit](https://github.com/torvalds/linux/commit/8d622d21d24803408b256d96463eac4574dcf067)? Yup, that definitely sounds believable for network hangs in a VM using the `virtio_net` driver.

This was great, but it still didn't explain why I could only repro it on
that one machine, nor why no one had noticed and fixed it yet. After some
experimentation, I found that running a VM with the above virtio commit on a
different host using a similarly old 4.12 kernel was what it took to repro
it.... meaning it was time for (you guessed it) *another git bisect*, this time
of the host kernel!

Now, initially I was thrilled at the prospect. The last bisect was easy thanks
to the power of NixOS! Unfortunately, this enthusiasm didn't last long.

### git bisecting 2: no VMs, old tools, and eventually no NixOS

Things went downhill rapidly. First, just slotting in the 4.12 kernel to the
NixOS `pkgs.linuxPackages_custom` didn't work. It turns out the first bisect
went so smoothly in part because I was only working with recent kernel
versions, but going 4+ years back in time had some bumps.

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

Okay, fine, it looks like selinux failed to compile. I guess we can just turn that off: `sed -i 's|CONFIG_SECURITY_SELINUX=y|CONFIG_SECURITY_SELINUX=n|' repro-host/kconfig`.

```
$ nixos-rebuild build --flake '.#repro-host
Unsupported relocation type: R_X86_64_PLT32 (4)
make[4]: *** [../arch/x86/boot/compressed/Makefile:118: arch/x86/boot/compressed/vmlinux.relocs] Error 1
```

This one also took _much_ longer to fail. Anyway, a short google later let me
know that I want an [older binutils](https://unix.stackexchange.com/questions/513921/how-to-get-around-r-x86-64-plt32-error-when-bisecting-the-linux-kernel)
to fix this. I decided to downgrade NixOS as a whole to an older version to
hopefully fix any other such issues. The NixOS versions that were around with
the 4.12 kernel all predate flakes, so I switched to the old
`/etc/nixos/configuration.nix` + `nix-channel` style of doing things. I didn't
take as good notes here, but suffice it to say, I still ran into more issues.
It was also very noticeable that nixpkgs didn't have a good mechanism for
incremental compilation (having to rebuild the kernel from scratch for each
change of practically anything), and that the normal advice of using ccache [wouldn't work](https://github.com/NixOS/nixpkgs/issues/153343).

In pursuit of incremental compilation, I went on a short adventure to try and
take a precompiled vmlinuz, and from that produce a valid initrd and boot NixOS
that way. Unfortunately, I couldn't figure out an easy way to slot in a
precompiled kernel and modules and get a working initrd. I tried creating an
[EFISTUB kernel and booting from that directly](https://firasuke.github.io/DOTSLASHLINUX/post/booting-the-linux-kernel-without-an-initrd-initramfs/), but the NixOS stage-1 seemed
rather important and difficult to emulate properly without an initrd.

I knew that on most distros, including Ubuntu, it's possible to [ditch the initrd](https://wiki.ubuntu.com/ImprovingBootPerformance), and at this point I
was tired of hopping between ancient NixOS channels and waiting for a full
non-incremental kernel build for each change, so I installed Ubuntu 18.04 (a
version old enough I thought it would build the 4.12 kernel with no complaint),
and tried to bisect from there.

This change from NixOS to Ubuntu instantly made the process less frustrating.
Running `make && sudo make modules_install && sudo make install` in a checkout
of the `4.12.x` kernel _just worked_, incremental compilation and grub entry
installation and everything. I didn't even have to disable the initrd since
`make install` built it for me, correctly and without any extra pain.

Switching to Ubuntu let me find [a commit](https://github.com/torvalds/linux/commit/8d65843c44269c21e95c98090d9bb4848d473853)
which fixed the bug when applied to the host, allowing me to run a newer or
older guest kernel without running into any network hangs.

This gave me enough information that I finally felt I could [report the issue upstream](https://lore.kernel.org/all/20220424230502.une24mt5sr65qcdk@Enkidudu/T/).

I think this is a satisfying conclusion to this investigation. It turns out
that the 4.12 kernel has a bug in the `vhost` side of `virtio-ring`, and a
recent optimization to the guest side of `virtio-ring` fairly reliably triggers
that bug in certain circumstances. This serves as a good forcing function to
make me finally replace that last Gentoo machine with NixOS, and it also let me
learn a bit along the way.

Speaking of, let's talk about a few learnings and and possible improvements.


### Learnings and Notes

#### NixOS might be the wrong tool for kernel bisects

I didn't mention it above, but I've done kernel git bisects in the past too. In
the past, my bisects have been considerably easier for a couple reasons. First,
in the past I've trimmed down the kernel config significantly more first
(admittedly, most of my previous bisects were on Gentoo, where I had a
hand-crafted minimal config already), which massively increased the iteration
speed. This was a boon. NixOS starts with a much thicker config, and has a
number of checks in its initrd build process and so on which require a rather
large baseline of modules.

Another difference, touched on above, is that NixOS makes it more difficult to
use a standalone kernel.

When possible, it's always great to perform a git bisect by effectively doing:

```
~/linux $ make
~/linux $ qemu-kvm -kernel arch/x86_64/boot/bzImage <other flags>
```

The iteration speed for this setup is great, but NixOS's desire to also own the
kernel build process, its desire to use an initrd that matches the kernel, and
the general difficulty of building such an initrd all conspire together to make
this difficult.

Next time I need to do a kernel bisect, I expect I'll spend a little more time
upfront trying to get it to reproduce in a simpler setup than NixOS.

That said, the tradeoffs aren't too bad. It doesn't actually matter that much
whether a `git bisect run` takes 3 hours or 12 hours if you'll be AFK anyway,
and I had fun setting up the first bisect described above.

#### Some kernel debugging notes

Actual kernel debugging tips are largely absent from the above post since I
focused on the bisecting part, but in reality, this investigation also included
staring at gdb backtraces and trying to divine information from `trace-cmd`
output.

This was largely from trying to understand the bug from just bisect 1 (which
ended up being unfruitful, the `vhost` side of things is where the interesting
info was). Still, I want to mention the following links and tools:

1. [`trace-cmd`](https://man7.org/linux/man-pages/man1/trace-cmd.1.html) is awesome.
    Check out `sudo trace-cmd record -p function_graph -g "vring_interrupt" -g "virtnet_poll" -n "printk"` + `trace-cmd report` if you want to see some fun call graphs
2. The [kernel GDB docs](https://01.org/linuxgraphics/gfx-docs/drm/dev-tools/gdb-kernel-debugging.html) are excellent.
3. [Dynamic debug](https://www.kernel.org/doc/html/v4.13/admin-guide/dynamic-debug-howto.html) in the linux kernel is awesome. `echo 'file virtio_ring.c +p' > /sys/kernel/debug/dynamic_debug/control` to immediately get debug logs in dmesg? Awesome.

I'll also give a shoutout to Red Hat's [virtio-ring](https://www.redhat.com/en/blog/virtqueues-and-virtio-ring-how-data-travels) posts. They're very helpful!

#### Possible NixOS Improvements

I'd like to use this section to speculate about ways NixOS could be improved
for the bisect flow I want. I'm personally a fan of NixOS, and it was
disappointing that Ubuntu gave me a better experience for bisecting an old
linux kernel.

Let's talk about some of the differences that made Ubuntu's flow better for this.

##### `/sbin/installkernel`

I mentioned that `make install` for Ubuntu "just worked". How does that work? Surely the Linux `Makefile` doesn't know how to run Ubuntu's `update-grub` or such, right? Well, it turns out the linux `Makefile` calls a custom install script at [`/sbin/installkernel`](https://github.com/torvalds/linux/blob/5bfc75d92efd494db37f5c4c173d3639d4772966/arch/x86/boot/install.sh#L37) if present, and Ubuntu [includes such a script](https://manpages.ubuntu.com/manpages/bionic/man8/installkernel.8.html).

It's hard to imagine how NixOS could do the same thing, after all a NixOS boot
entry specifies the entire system configuration, and it doesn't seem feasible
for NixOS to rebuild that configuration itself. It's possible to build a NixOS
system configuration using a flake on another machine, or to make impure
references to files that may not even exist anymore.

Providing a mechanism like this in NixOS would probably require having some
sort of "impure" boot entry, where a kernel and initrd are used which "don't
match" the NixOS configuration they boot.

All this said, I think there's still value in providing such a mechanism if
it's feasible.

##### Externally Built Kernel

Currently, NixOS provides `linuxPackages_custom` to build a custom kernel
version. I couldn't find any equivilant mechanism to point
`boot.kernelpackages` at a pre-built kernel and its modules. This mechanism
would have made incremental compilation much easier, especially when adding
printk debugging statements and rebuilding.

It doesn't seem to me like there's any fundamental reason that prebuilt
binaries can't be plugged in as inputs here, and it's simply a matter of
someone wiring it up.

On Ubuntu, this is of course trivial: just `make install` them into place.

##### Booting With no Initrd

Skipping the initrd is one way to somewhat speed up iteration times. Most linux
distros allow you to not have an initrd at all. It's a necessity in many setups
(i.e. to luks decrypt the partition containing your rootfs, or to do LVM
setup), but most distros can be configured in such a way that you don't need
it. An Ubuntu installation without encryption or luks will happily boot an
EFISTUB kernel without an initrd.

NixOS, on the other hand, has no documented way to boot without an initrd that
I know of.

### Final Thoughts

Git bisecting is fun. I highly recommend using [`git bisect run`](https://lwn.net/Articles/317154/) whenever possible.

It's a testament to the quality of the linux repository that I had zero skips in my git bisects of it (i.e. all commits my bisect needed built and at least booted).

Oh, also, update your machines frequently. Updating that VM host any time in
the past 3 years would have saved me hours of sleep.

----

Thanks for reading :)
