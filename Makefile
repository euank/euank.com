.PHONY: all serve docker-image
all:
	bundle exec jekyll build

serve:
	bundle exec jekyll serve -l -H 0.0.0.0

docker-image:
	docker build -t "euank/euankcom:$(shell git rev-parse --short HEAD)" .
