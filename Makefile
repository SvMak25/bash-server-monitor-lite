SHELL := /bin/bash

.PHONY: lint test

lint:
	shellcheck monitor.sh

test:
	bash tests/run.sh
