---
layout: post
title: Rust on Lambda
---

# Running Rust on Lambda

[AWS Lambda](https://aws.amazon.com/lambda/), at the time of writing, does not
support [Rust](https://rust-lang.org/). Fortunately, a few entrepreneurial
individuals have ignored the lack of support and made it work anyways! The main
projects I know that allow running rust on Lambda are
[`crowbar`](https://github.com/ilianaw/rust-crowbar) and [Rust on AWS
Lambda](https://github.com/srijs/rust-aws-lambda). There are other projects,
such as [lando](https://github.com/softprops/lando) and
[serverless-rust](https://github.com/softprops/serverless-rust), which
ultimately use `crowbar` under the hood.

Given both `crowbar` and `Rust on AWS Lambda` exist, it seems reasonable to ask
"which of these is faster? Which should I use?" This blog post presents a brief
introduction to the projects, some toy benchmarks, and some information on
usability.

Before getting into that though, let's talk about how the various methods of
running Rust on Lambda work under the hood.

# How do they work?

## crawbar -- Build a shared library to run via python

The [`crowbar`](https://github.com/ilianaw/rust-crowbar) project takes
advantage of the fact that cpython will happily load a shared object file as a
python module.
Writing a cpython module in Rust is fairly easy using the [rust-cpython](https://github.com/dgrunwald/rust-cpython) project.
crowbar effectively provides glue code between `rust-cpython` and Lambda's python environment.

## Various -- Spawn a rust binary, talk over stdin/stdout

There are various projects, none of which seem to have gained much traction,
which simply provide some abstractions around spawning a child process from the
NodeJS environment and passing requests and responses back and forth over
stdin/stdout.
This works, but each project is defining an ad-hoc protocol for plumbing
information between their chosen runtime and Rust, and most of them execute a
fresh child process per request, whereas all normal lambda environments re-use
one process for many requests.

Because none of them seem very popular and because they vary wildly in quality,
I've skipped over them entirely in my comparison.

## Rust on AWS Lambda -- Just sorta look like Go, you know?

After the creation of the previous two methods of running Rust on Lambda,
Lambda released support for Go.
The way Lambda's Go support works is by launching a binary the user uploads and
then speaking a specific RPC protocol to it over a TCP port.
AWS provides a library to make it easy to do this in Go, but there's no reason
the zipfile actually has to contain a Go binary.
Rust on AWS Lambda runs Rust code in the Go Lambda environment, but unlike the
previous two methods, it doesn't require any non-Rust code at all.

# Benchmarks -- Which way is the fastest?

One thing to consider when picking a method of running Rust code on Lambda is how fast it is.
In this section, I present the results of benchmarking each of these methods along with a non-Rust function using the same language environment.
Unfortunately, these results may change over time with no notice due to AWS updating or changing how they run Lambda functions.

I'm just trying to measure the overhead of the framework and runtime
environment, not the actual code being run, so I'm measuring a trivial "hello
world" example (given an empty payload) in each case.

I'm specifically benchmarking the following environments.

* Go (using Go code)
* Go (using Rust on AWS Lambda)
* Python (using python code)
* Python (using crowbar to run Rust)

## Prior Art

[This](https://medium.com/@nathan.malishev/lambda-cold-starts-language-comparison-%EF%B8%8F-a4f4b5f16a62) medium post by Nathan Malishev benchmarks the cold start time for various runtimes.
However, none of the benchmarks included Rust anywhere in the mix, and the numbers appear to have changed since then.
Nonetheless, I feel it's necessary to mention this blog post as it served as an
inspiration for my methodology (using XRay to measure execution time) and gave
me a baseline to compare against.

Since that blog post did not share detailed information on its methodology (to
the point of not even mentioning the region being benchmarked), I had to
effectively start from scratch.

## Methodology

All of the lambda functions, benchmark code, and results are available in [this
repository](https://github.com/euank/lambda-bench).

All of data was collected within 3 days of September 14th, 2018 in the
`us-west-2` region. This matters because Lambda's performance will doubtlessly
change over time (hopefully for the better).
I measured "cold" and "warm" starts. For my purposes, a lambda's start was
considered to be "cold" when no other lambda had been executed in that AWS
account for 45 minutes.
A "warm" start was considered to be any additional run within a short period,
under a minute, after a previous execution of the lambda in question.

In practice, this meant my data was collected by going through the following steps:

1. Create 4 lambda functions, each printing "Hello World" from a different framework.
2. Wait 45 minutes
3. Execute one function (cold)
4. Wait 10s
5. Execute the same function (warm)
6. Go to step 2 until all functions have been executed
7. Collect XRay traces for all previous function executions and store them

Note that it turns out that the above is overly cautious. Simply creating and
immediately executing a lambda function seems to give fairly similar times as
waiting 45 minutes and executing it, so I could have saved numerous hours by
simply creating a lambda, collecting a cold and warm data points, deleting it,
and continuing to the next one in a similar fashion.

Despite the slow methodology I chose, I still managed to parallelize it by
using several AWS Organization accounts dedicated to this purpose. Since each
account is largely independent, I could parallelize data collection between
them without a worry of accidentally heating up other Lambdas.

One final precaution I took (which is also unnecessary I believe) was to toss a
few random bits into each uploaded zip file to ensure none of them could be
cached.

## Results

And now for the results! The below graph shows data collected over around 40
executions of each Lambda function (half warm and half cold).

![Lambda plot](/imgs/lambda-bench/plot.png)

The raw data is available
[here](https://github.com/euank/lambda-bench/blob/d5b3dda1/results-2018-09-14/merged.csv)
if you wish to process it for your own purposes.

The main data I was interested in was the cold execution time. We can
immediately see, at a glance, that python, crowbar, and Rust on AWS Lambda all
have very similar cold execution times (at around 250ms), while Go's cold-start
time is drastically slower, and more variable as well.
In fact, this chart omits outliers, or else there would be one 739ms data point
for Go... None of the other functions had such an extreme outlier.

Rust on AWS Lambda generally was slightly quicker than the other frameworks by a
small margin and it also had the fastest cold start time measured, at 173ms.
This still pales in comparison to every warm start (the slowest of which was
104ms, a significant outlier from Rust on AWS Lambda's warm executions).

Speaking of warm starts, crowbar and python were neck-and-neck, and both
handily beat Go and Rust on AWS Lambda by good margins. Of course, these margins
are measured in milliseconds, so it will almost certainly vanish in the noise
of a Lambda doing real work, not just printing "Hello World".

I suspect that part of the cold start time can be attributed to the size of each deployment zip.

| Function | Zip file size | &nbsp; Uncompressed size |
|----------|--------------:|------------------:|
| python   | 245 B         | 85 bytes          |
| crowbar  | 774 KB        | 2.91 MB           |
| go       | 4.2 MB        | 8.41 MB           |
| Rust on AWS Lambda       | 1.6 MB | 5.17 MB  |

As I understand it, on each cold start Lambda will download the deployment zip file from S3 and extract it. That means the startup time will include the time it takes to copy the bytes over the network and the time it takes to write them to disk.
Since this is within the same region (and probably same AZ), these times should
be quite small, but the differences I'm measuring on cold starts are already
fairly small.
The difference in size between Go binaries and the other binaries is the best
explanation I've got for why Go's so slow here.

## Conclusion

I think it's fair to say that crowbar and Rust on AWS Lambda both perform quite
well (in fact, both seem to perform better than the language intended to run in
their respective environments).

The cold and warm startup times are quite comparable for trivial programs.

# Ease of Use

Now that we've seen both crowbar and Rust on AWS Lambda have very similar
performance, let's look at the ease of use of each.

## crowbar

It took me longer to get a working crowbar lambda than all the others combined.
Building a dynamically linked shared library in Rust is fairly easy.
Building one for a cloud environment that might have a broken python
configuration is a bit harder.

The [rust-cpython](https://github.com/dgrunwald/rust-cpython) crate is great,
but it's also difficult to debug. If you're curious, it invokes python code
[like so](https://github.com/dgrunwald/rust-cpython/blob/0.1.0/python3-sys/build.rs#L278-L282)
to determine various linker flags rather than invoking the more standard
`pkg-config`.

Ultimately, I had to add [this](https://github.com/euank/lambda-bench/blob/d5b3dda19848b9ed237dfad62c9a88f790b4e2ee/crowbar/Makefile#L12) strange line to my Makefile to get my crate to link at all.

Furthermore, I hear I'm getting off easy because I don't have to deal with
linking against [openssl](https://github.com/ilianaw/rust-crowbar/issues/20),
just `libpython3.6m`.

## Rust on AWS Lambda

That's not to say Rust on AWS Lambda is a blameless holy project either. I
wanted to just type `cargo build --release`, zip it up, and be done, but the reality is less ideal.

Sure, I didn't have to deal with a strangely packaged python library, but
Lambda's copy of `glibc` is old enough no modern Linux Distro will build a
binary compatible with it by default.

Fortunately, the `lambci` project has a wonderful [`go-build`](https://github.com/lambci/docker-lambda/blob/v0.15.3/go1.x/build/Dockerfile) image which makes building a Rust on AWS Lambda function [fairly straightforward](https://github.com/euank/lambda-bench/blob/d5b3dda19848b9ed237dfad62c9a88f790b4e2ee/rust-aws-lambda/Makefile).

It's also possible to create statically linked Rust binaries, but it's still a bit tricky.

## Conclusion

I found Rust on AWS Lambda to be easier to get deployed, in no small part due
to not having to deal with Lambda's messily configured libpython.

Both crowbar and Rust on AWS Lambda required building in a docker container due
to library differences, but for Rust on AWS Lambda, that was the only hurdle to
leap over.
