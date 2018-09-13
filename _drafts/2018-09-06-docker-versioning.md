---
layout: post
title: Docker Versioning
---

# Docker: A Fractal of Bad Versioning

Docker Inc. has had more than its share of versioning mishaps and release
management issues.

This post is an attempt to document some of them into a cohesive narrative,
though I'll also include an appendix listing all known issues, including those
not mentioned in my narrative.

The goal of this narrative is to specifically call out things which you might
do differently if you wish to do a better job versioning and releasing your own
software.

## My background

First, I'll add my background as it relates to this. I've used docker, both
professionally and on the side, for the better part of its existence.

I developed the [ECS Agent](https://github.com/aws/amazon-ecs-agent) (which makes heavy use of the Docker API), worked some on Kubernetes (which also makes heavy use of Docker's API), and helped package Docker for [Container Linux](https://coreos.com/os/docs/latest/) (aka CoreOS).

These positions have given me ample opportunity to observe these issues.

## Disclaimer

Before going further, I'd like to include a disclaimer.
