---
layout: post
title: S3's CORS is dumb. Here's how to ignore it!
---

# S3's CORS is dumb. Here's how to ignore it!

## Introduction

Today we're going to talk about AWS S3's (lack of) Cross-Origin Resource Sharing (CORS) headers and why the
whole thing is silly in the context of S3.

This post is going to first explain a bit about what CORS is and what
theoretical benefit it it might have for S3 if, you know, it worked.  After
that, I'll go into a technical explanation of why it totally doesn't actually
work for S3, including walking through some code to break it.  Finally, I'll
talk about some existing art for breaking it.

## What is CORS?

Before we get into the S3 side of things, let me quickly explain what CORS is.
There's dozens of explanations online, but many of them get bogged down in technical details immediately.
I'll try to explain it by talking about the specfic problem it solves, and the
high level details of how it solves it. I won't go too far into the weeds since
only a general understanding is needed to understand the rest of the blog post.

First, let's talk about why CORS exists by using the cliché example of a bank.
Assume the user is logged into their bank and the bank shows their account
information at `https://bankwebsite.example/user/my-accounts`. When the user
visits that URL directly, the server is able to recognize them and serve up
their account numbers because the browser sends along a [Cookie](https://developer.mozilla.org/docs/Web/HTTP/Cookies) identifying the user securely.
While still logged into their bank, the user then visits
`https://take.mallorys-evil.test` which includes the following JavaScript code:

```js
fetch('https://bankwebsite.example/user/my-accounts', {credentials: 'include'})
  .then((response) => {
    exfiltrateData(response);
  });
```

Fortunately, that code will fail because Cross-Origin requests made via
Javascript are blocked by default due to CORS. "Origin" here means the domain
name, in this case `https://take.mallorys-evil.test`, as sent in the [Origin
header](https://developer.mozilla.org/docs/Web/HTTP/Headers/Origin). If the
Origin on the request doesn't exactly match the origin the request is to, it
will be blocked by default.

Note that all Javascript-initiated requests, even those without credentials, are blocked. Other types of requests, like `<img src="https://bankwebsite.example/logo.png" />` (which results in a browser-initiated request) are not blocked, but Javascript's ability to manipulate these tags is [restricted](https://developer.mozilla.org/docs/Web/HTML/CORS_enabled_image).

What if the bank above also hosts a mobile website at
`https://m.bankwebsite.example`, and wants to send a request to an endpoint on
`https://bankwebsite.example` from Javascript? Since the Javascript running on
the mobile website can be trusted, that should be perfectly fine, but the
Origin differs, so it will still be blocked... Until the developer adds an
appropriate `CORS` header to `https://bankwebsite.example`! In this specific
example, the headers would probably look like so:

```http
Access-Control-Allow-Origin: https://m.bankwebsite.example
Access-Control-Allow-Methods: POST, GET, OPTIONS
Access-Control-Allow-Headers: Content-Type
Access-Control-Allow-Credentials: true
```

This set of headers lets the browser know to allow Javascript running on `https://m.bankwebsite.example` to make requests to `https://bankwebsite.example`, including with credentials (cookies) set.

Now, there's more to CORS than that (namely preflight requests, other special
cases beyond images, and other such details), but the above should be enough
background for the purpose of this post.

## What's S3's CORS setup?

By default, S3 provides no CORS headers, meaning all requests to the S3 API and
objects in S3 buckets from Javascript are blocked.

The [JavaScript SDK's
documentation](https://aws.amazon.com/developers/getting-started/browser/)
notes that "CORS needs to be configured on the Amazon S3 bucket" to use the
SDK, and walks you through setting it up.

The more detailed [CORS
documentation](https://docs.aws.amazon.com/sdk-for-javascript/v2/developer-guide/cors.html)
repeats this information.

Put more succinctly, S3 allows users to apply CORS headers on a per-bucket
basis, but does not provide headers to allow requests that don't target a
bucket (e.g. `ListBuckets`).

However, as you might be able to guess from the title of this post, the (lack
of) CORS headers can be easily bypassed and shouldn't ever be relied on for
security. We'll get to that bit soon, I promise!

### When might S3 CORS matter?

Let's look at 2 (2️⃣ ) specific cases where S3's CORS headers (or lack thereof) might matter.

Note that neither of these cases is typical, and in reality there are very few
good reasons to make S3 API calls directly from a user's browser.

#### Client-side Webpage Using S3

Let's say you want to create an entirely client-side website which allows the
user to store files in S3 in *their* account.

You could have the user enter their AWS access and secret keys and then use them to make requests from within their browser. This is simple to reason about, and more secure than any similar server-side solution.

Unfortunately for you, CORS will block any requests the browser makes to list or create buckets, even if the user enters correct credentials.
Your dastardly plan to provide a secure serverless experience has been foiled!

#### Access Public Data in S3

There are various [public datasets](https://registry.opendata.aws/) on S3, and
some may be useful to browse and/or manipulate from client-side JavaScript.

By default, buckets do not have CORS headers though, so in most cases you will
be foiled by bad defaults.

## Breaking S3's CORS

CORS, no matter what, never blocks a request from the same origin. That is to say, if JavaScript is running on `s3.amazonaws.com`, no request to `s3.amazonaws.com` will ever be blocked.
If only there was a way to run arbitrary JavaScript on that origin... like if they let us upload an html file to `s3.amazonaws.com/my-bucket-name/my-file.html`!
With that, it's easy to see why CORS on S3 doesn't work. Any origin that allows
user-submitted arbitrary html content absolutely cannot expect any combination
of CORS headers to be effective.

For the sake of having a concrete example, let's say that we wish to build a
simple client-side webpage that lets a user enter their AWS credentials to
store content created on the webpage in their S3 bucket.

This falls under the first reason S3's CORS setup matters above. To provide a
reasonable UX to the user, this webpage will likely want to list their buckets,
optionally offer to create one, and be able to upload files to an existing
bucket even if it has no CORS configuration.

To keep this blog post short, we'll just write the bucket-lister portion, but
hopefully the above example use-case makes sense.

A first swing at naively writing this might look like the following (using vuejs):

`bucket_lister.js`:
```js
var app = new Vue({
  el: '#app',
  data: {
    accessKey: '',
    secretKey: '',
    errorText: '',
    // ... some code omitted
  },
  methods: {
    listBuckets: function() {
      // ...
      const creds = new AWS.Credentials({
        accessKeyId: this.accessKey,
        secretAccessKey: this.secretKey,
      });
      AWS.config.update({region: 'us-east-1', credentials: creds});
      const s3 = new AWS.S3();
      s3.listBuckets().promise()
      .then((data) => { 
        this.buckets = data.Buckets;
      })
      .catch((err) => {
        this.errorText = err.toString();
      });
    },
  },
});
```

This looks like reasonable code, but if we run it [here](/blog/examples/cors-pfff/v1/bucket_lister.html), you'll see that it doesn't work.

The error it provides is a rather generic "NetworkError", but if you look at the browser console, it goes into more detail in explaining that CORS blocked it.

![Image of CORS errors in browser console](/imgs/cors-pfff/browser-console-cors-blocked.png)

What if we upload exactly the same code into an S3 bucket? I've gone ahead and put the exact same `bucket_lister.html` in a bucket named `euank-com-examples`, available [here](https://s3.amazonaws.com/euank-com-examples/cors-pfff/v1/bucket_lister.html). As you can see, the same code now works!

This is one way to defeat S3's CORS: just host your stuff on S3 and have users interact with it there. However, I'd like to do better. I'd much prefer users visit my preferred origin (in this example `euank.com`), not a strange looking `s3.amazonaws.com` URL.

Fear not, for combining the above information with an [iframe](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/iframe) will let us defeat CORS from any origin!

This trick relies on a few nifty facts:

1. CORS does not block iframes.
2. The [postMessage](https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage) API has only opt-in origin checks.
3. The origin which embeds an iframe does not affect its CORS same-origin status in the slightest.

Putting all these together, it seems clear that if we can get a page on the
same origin as the S3 APIs which accepts `postMessage` requests to make API
calls on our true origin's behalf, we can trivially work around CORS.
As luck would have it, hosting arbitrary HTML on the same origin as S3 is one of S3's key features!

Our second version of the above code is now split into more files. Here's the important snippets:

`proxy.html`:
```html
<script src="https://sdk.amazonaws.com/js/aws-sdk-2.349.0.min.js"></script>
<script>
    // 'message' events come from the parent window on euank.com
    window.addEventListener('message', function(event) {
        const result = {};
        const creds = new AWS.Credentials(event.data.creds);
        AWS.config.update({region: 'us-east-1', credentials: creds});
        const s3 = new AWS.S3();
        s3.listBuckets().promise()
        .then((data) => { 
            result.error = false;
            result.buckets = data.Buckets;
            result.listingBuckets = false;
            // the postMessage Web API lets us respond to euank.com as well
            event.source.postMessage(result, event.origin);
        })
        .catch((err) => {
            result.listingBuckets = false;
            result.errorText = err.toString();
            result.error = true;
            event.source.postMessage(result, event.origin);
        });
    }, false);
</script>
</html>
```

`bucket_lister.html`:
```html
<iframe src="https://s3.amazonaws.com/euank-com-examples/cors-pfff/v2/proxy.html" v-on:load="iframeLoaded" style="display:none;"></iframe>
```

`bucket_lister.js`:
```javascript
var app = new Vue({
  el: '#app',
  data: {
    iframe: {
      loaded: false,
    },
    accessKey: '',
    secretKey: '',
    // ...
  },
  methods: {
    iframeLoaded: function() {
      this.iframe.loaded = true;
      window.addEventListener('message', (ev) => {
        // copy the iframe results back into our vue data object
        Object.assign(this, ev.data);
      }, false);
    },
    listBuckets: function() {
      if (!this.iframe.loaded) {
        this.error = true;
        this.errorText = "iframe still loading; please try again shortly";
        return;
      }
      // ...
      // Kindly ask the iframe to list buckets using the provided credentials
      const ifr = document.querySelector("iframe");
      ifr.contentWindow.postMessage({
        creds: {
          accessKeyId: this.accessKey,
          secretAccessKey: this.secretKey,
        },
      }, '*');
    },
  },
});
```

With these changes, you can go to a version hosted on the `euank.com` origin [here](/blog/examples/cors-pfff/v2/bucket_lister.html), and this time it should work!

Note that we have not configured any CORS headers anywhere, but by taking
advantage of being able to host arbitrary pages on the target origin, we can
still ignore any and all CORS headers with ease.

There are many ways that this solution could be further improved (such as by
not hard-coding `proxy.html`'s code to make only one API call), but rather than
continue working with this solution, let's look at existing art and see if
there are even better tricks we can use.

### Using XHook / XDomain / S3 Hook

While the above method of breaking S3's CORS works and does a good job of
explaining why the whole thing is silly to begin with, it's technically
possible to do something even more general and clever.

Ultimately, the only thing that actually needs to run in the iframe is the
specific XMLHttpRequests which would otherwise be blocked by CORS.

[Jaime Pillora](Jaime Pillora), in 2013, created a series of projects to handle this very problem at the XMLHttpRequest layer. These projects are [XHook](https://github.com/jpillora/xhook), [XDomain](https://github.com/jpillora/xdomain), and [S3 Hook](https://github.com/jpillora/s3hook).

In fact, his [S3 Hook example](http://jpillora.com/s3hook/) is suspiciously
similar to the example I've been using (but much more fleshed out).

Unfortunately, it's hacky in its own way. Sure, the proxy implementation can be
quite generic, but XHook accomplishes this by attempting to implement the full
XMLHttpRequests specifications, which has been a recipe for missing edge cases.

What this means in practice is that to convert my above example to use XDomain,
I had to spend significant time debugging an issue with it, and I still don't
fully understand the [fix](https://github.com/jpillora/xhook/pull/98) I
eventually stumbled upon.

With the afore-mentioned patch to XHook, it's possible to rewrite our original example as:

`proxy.html`:
```html
<script src="https://s3.amazonaws.com/euank-com-examples/cors-pfff/v3/xdomain.min.js" master="*"></script>
```

`bucket_lister.html`:
```html
...
<script src="https://s3.amazonaws.com/euank-com-examples/cors-pfff/v3/xdomain.js" slave="https://s3.amazonaws.com/euank-com-examples/cors-pfff/v3/proxy.html"></script>
<script src="https://sdk.amazonaws.com/js/aws-sdk-2.349.0.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/vue@2.5.17/dist/vue.js"></script>
<script src="./bucket_lister.js"></script>
...
```

`bucket_lister.js`:
```js
var app = new Vue({
  el: '#app',
  data: {
    accessKey: '',
    secretKey: '',
    errorText: '',
    // ... other data omitted
  },
  methods: {
    listBuckets: function() {
      // ...
      const creds = new AWS.Credentials({
        accessKeyId: this.accessKey,
        secretAccessKey: this.secretKey,
      });
      AWS.config.update({region: 'us-east-1', credentials: creds, s3ForcePathStyle: true});
      const s3 = new AWS.S3();
      s3.listBuckets().promise()
      .then((data) => { 
        this.buckets = data.Buckets;
      })
      .catch((err) => {
        this.errorText = err.toString();
      });
    },
  },
});
```

You can see this code working [here](/blog/examples/cors-pfff/v3/bucket_lister.html).

Notably, the code in `bucket_lister.js` making use of the AWS SDK doesn't have
do anything different; the XMLHttpRequests to the proxy's origin are
transparently routed through an iframe to the proxy with no ceremony.

Still, I would be a little wary of this hack. It is nearly certain that the
fake XMLHttpRequest XHook simulates has differences from the real thing, and
changes to the AWS SDK in the future might run into these edge cases.

It is worth noting that it, like the previous solution, exhibits additional
latency due to needing to load an iframe and communicate with it.

## Regions

So far I've only been using the 'us-east-1' region. It's worth noting that most
S3 operations need to go to a regional endpoint, which means you have a
different origin against which to break CORS. It turns out CORS circumvention
is a regionalized venture :).  It's easy enough to adapt anything above to
multiple regions simply by having more buckets.

# Concluding Thoughts

The (lack of) CORS headers on S3's endpoints do nothing to stop anyone
determined to avoid them. I suspect that the only reason they're not
present to begin with is because when S3 was originally released (in 2006),
CORS was not in wide-spread use (added to Firefox in
[2008](https://bugzilla.mozilla.org/show_bug.cgi?id=389508), if you were
curious). Once S3 didn't have CORS headers, it was more difficult to add them
-- after all, clearly things are working just fine without them, right? It only
leads to multiple pages of the AWS SDK docs having to explain the silly-ness
and why some SDK features don't work from the JavaScript SDK in the browser.

In practice, S3's CORS headers should rarely matter since it is usually neither
good UX nor a good idea to implement software that needs to access top-level S3
APIs from the browser.  However, if you find yourself running into this issue,
hopefully this blog post will help you to open an iframe and breeze right
through them.
