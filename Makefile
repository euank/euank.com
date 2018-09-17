.PHONY: all serve
all:
	bundle exec jekyll build

serve:
	bundle exec jekyll serve -l -H 0.0.0.0
