---
layout: post
title: Advent of Code 2021 &mdash; Notes on my Nix Solutions
---

## Introduction

This post is about my solutions to the 2021 Advent of Code puzzles. Be warned that there will be spoilers. If you're planning to do them, you might have more fun going through them before reading this post!

If you're not familiar, the [Advent of Code](https://adventofcode.com/about) is a fairly well popularized set of programming puzzles run each December. They're well made, well themed, and quite fun. They're also designed to be completable in just about any programming language.

The post title already spoiled it, but I wrote all my solutions in [nix](https://github.com/euank/advent-of-nix-2021).

### What is nix?

The nix expression language (or nix for short) is a purely functional, lazily-evaluated, dynamically typed programming language. It's not really a general purpose programming language as its primary intent is to declaratively define packages and configuration for the nix package manager and NixOS operating system (respectively). It still can be used as a general purpose programming language for many tasks as it's turing complete, capable of disk IO, and capable of very limited network IO.

This blog post will assume some basic familiarity with the language. If you want an introduction to it, [this one pager](https://github.com/tazjin/nix-1p), and the [NixOS Wiki](https://nixos.wiki/wiki/Nix_Expression_Language) both are great resources to jump off from.

### Why nix?

Why did I use nix for the advent of code? Well, it definitely wasn't because it's well-suited to it. Nix is not really meant to be a general purpose programming language, but rather is primarily meant to declaratively define packages and operating system configuration for the nix package manager and NixOS respectively.


### What I'll be covering

This post will cover two different-but-related threads. Firstly, I'll talk
about some vague learnings that I think apply more broadly to writing nix code.
Second, I'll talk about a couple specific days that were perticularly unsuited
to nix and why.

## Learnings and misc notes

###

### Debugging nix

builtins.trace

### sublist
