# Test Description: Topic 13 - Ollama IP Split

## What Changed
Updated the Docker networking note in README to explicitly state that the same gateway IP (172.17.0.1) should be used for both Qdrant and Ollama, and to never use container IPs.

## How to Know It Works
README Docker networking note mentions using the same gateway IP everywhere.
