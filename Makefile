.PHONY: test build lint parity docker-test

IMAGE ?= ml-model-go-dev
VERSION ?= dev

test: docker-test

docker-test:
	docker build --target test -t $(IMAGE)-test --build-arg VERSION=$(VERSION) .
	@echo "tests passed in Docker"

build:
	docker build -t $(IMAGE):$(VERSION) --build-arg VERSION=$(VERSION) .

lint:
	docker run --rm -v "$(CURDIR)":/app -w /app golangci/golangci-lint:v2.1.6 golangci-lint run ./...

parity:
	./scripts/parity.sh
