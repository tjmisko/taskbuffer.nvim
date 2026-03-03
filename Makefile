.PHONY: build test test-lua lint clean

build:
	cd go && go build -o task_bin .

test:
	cd go && go test ./...

test-lua:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

lint:
	stylua --check lua/ plugin/ tests/
	selene lua/

clean:
	rm -f go/task_bin
