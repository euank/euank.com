---
layout: post
title: Modern Package Managers
---

# Modern Package Managers

Package management has changed. There was a time when each machine had one
package manager installed on it, and that was it.

Sure, `/usr/local` and `/opt` might have had a smattering of *stuff* that the
package manager dutifully ignored, but those files were swept under the rug,
not celebrated.

Today, when a new language comes into existence, it must include some sort of
package manager with it. At some point between CPAN and NodeJS, it became
unthinkable to do anything but create a package manager, package registry, and
the nth custom format for describing a package's dependencies.

To me, this is an indictment of traditional package managers. User's needs
evolved, and the package managers did not keep up.

## Why do Language Specific Package Managers Exist

At this point I think it's valuable to begin speaking of specific package
managers for comparison. I'll use aptitude and dpkg as the specific package
manager and package format I use here, but the points I'm making apply to most
system package managers basically identically, with the exception of certain
modern ones like `nix`.

So, why were existing package managers deemed unsuitable for language package management?
