.PHONY: start test-orch fmt lint clean

start:
	./start.sh

test-orch:
	cd orchestrator && GOCACHE=/tmp/go-build-cache go test ./...

fmt:
	gofmt -w orchestrator/*.go

lint:
	@echo "No lint target configured yet."

clean:
	rm -f orchestrator/orchestrator.log dashboard/dashboard.log orchestrator/.orchestrator.pid dashboard/.dashboard.pid
