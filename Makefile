.PHONY: all serve docker-image sync-examples
all:
	bundle exec jekyll build

serve:
	bundle exec jekyll serve --drafts -l -H 0.0.0.0

docker-image:
	nix build '.#'
	docker load -i ./result

sync-examples:
	cd blog/examples && aws s3 sync . s3://euank-com-examples
