.PHONY: test test-lua test-install bench helptags test-e2e test-e2e-lazy test-e2e-vimplug \
	test-e2e-us-dates test-e2e-eu-dates test-e2e-custom-checkbox \
	test-e2e-12h-time test-e2e-minimal-wrapper test-e2e-all lint clean demo demo-check

test: test-lua

test-lua:
	python3 scripts/test-lua.py

test-install:
	python3 scripts/install-smoke.py

bench:
	python3 scripts/benchmark.py $(BENCH_ARGS)

demo:
	python3 scripts/demo.py $(DEMO_ARGS)

demo-check:
	python3 scripts/demo.py --check $(DEMO_ARGS)
	nvim --headless -u NONE -i NONE -l scripts/demo/test_obs.lua

helptags:
	nvim --headless -u NONE -i NONE -c 'helptags doc' -c 'qa!'

test-e2e:
	docker build -t taskbuffer-e2e .
	docker run --rm taskbuffer-e2e

test-e2e-lazy:
	docker build -f tests/e2e/Dockerfile.lazy -t taskbuffer-e2e-lazy .
	docker run --rm taskbuffer-e2e-lazy

test-e2e-vimplug:
	docker build -f tests/e2e/Dockerfile.vimplug -t taskbuffer-e2e-vimplug .
	docker run --rm taskbuffer-e2e-vimplug

test-e2e-us-dates:
	docker build -f tests/e2e/Dockerfile.us-dates -t taskbuffer-e2e-us-dates .
	docker run --rm taskbuffer-e2e-us-dates

test-e2e-eu-dates:
	docker build -f tests/e2e/Dockerfile.eu-dates -t taskbuffer-e2e-eu-dates .
	docker run --rm taskbuffer-e2e-eu-dates

test-e2e-custom-checkbox:
	docker build -f tests/e2e/Dockerfile.custom-checkbox -t taskbuffer-e2e-custom-checkbox .
	docker run --rm taskbuffer-e2e-custom-checkbox

test-e2e-12h-time:
	docker build -f tests/e2e/Dockerfile.12h-time -t taskbuffer-e2e-12h-time .
	docker run --rm taskbuffer-e2e-12h-time

test-e2e-minimal-wrapper:
	docker build -f tests/e2e/Dockerfile.minimal-wrapper -t taskbuffer-e2e-minimal-wrapper .
	docker run --rm taskbuffer-e2e-minimal-wrapper

test-e2e-all: test-e2e test-e2e-lazy test-e2e-vimplug \
	test-e2e-us-dates test-e2e-eu-dates test-e2e-custom-checkbox \
	test-e2e-12h-time test-e2e-minimal-wrapper

lint:
	stylua --check lua/ plugin/ tests/ scripts/demo/
	selene lua/

clean:
	rm -rf .deps .repro
