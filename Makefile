.PHONY: all serve docker-image sync-examples
all: sync-examples
	bundle exec jekyll build

serve:
	bundle exec jekyll serve --drafts -l -H 0.0.0.0

docker-image:
	docker build -t "euank/euankcom:$(shell git rev-parse --short HEAD)" .

sync-examples:
	cd blog/examples && aws s3 sync . s3://euank-com-examples
