# SIMTiX root shim — delegates to the Verilator harness in sim/
.PHONY: lint test clean
lint test clean:
	$(MAKE) -C sim $@
