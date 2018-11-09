var app = new Vue({
  el: '#app',
  data: {
    accessKey: 'AK' + 'IAIMWQYYF3PZILYTKQ',
    secretKey: '9f' + 'SM72OPrGKJAEVofRJo6VZAr3y7BsyW/hFMneqn',
    listingBuckets: false,
    error: false,
    errorText: '',
    buckets: [],
  },
  methods: {
    listBuckets: function() {
      this.error = false;
      this.buckets = [];
      this.listingBuckets = true;

      const creds = new AWS.Credentials({
        accessKeyId: this.accessKey,
        secretAccessKey: this.secretKey,
      });
      AWS.config.update({region: 'us-east-1', credentials: creds, logger: console, s3ForcePathStyle: true});
      const s3 = new AWS.S3();
      s3.listBuckets().promise()
      .then((data) => { 
        this.error = false;
        this.buckets = data.Buckets;
        this.listingBuckets = false;
      })
      .catch((err) => {
        this.listingBuckets = false;
        this.errorText = err.toString();
        this.error = true;
      });
    },
  },
});
