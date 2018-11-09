var app = new Vue({
  el: '#app',
  data: {
    iframe: {
      loaded: false,
    },
    accessKey: 'AK' + 'IAIMWQYYF3PZILYTKQ',
    secretKey: '9f' + 'SM72OPrGKJAEVofRJo6VZAr3y7BsyW/hFMneqn',
    listingBuckets: false,
    error: false,
    errorText: '',
    buckets: [],
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
      this.error = false;
      this.buckets = [];
      this.listingBuckets = true;

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
