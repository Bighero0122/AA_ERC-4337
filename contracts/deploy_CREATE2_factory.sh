#!/usr/bin/env bash

CREATE2_ADDRESS="0x4e59b44847b379578588920cA78FbF26c0B4956C"
curl http://localhost:8545 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\", \"id\":1, \"method\": \"anvil_setCode\", \"params\": [\"$CREATE2_ADDRESS\", \"0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3\"]}"