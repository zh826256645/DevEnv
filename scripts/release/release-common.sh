#!/bin/bash

RELEASE_SEMANTIC_VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'

release_is_semantic_version() {
    local version="$1"
    [[ "$version" =~ $RELEASE_SEMANTIC_VERSION_PATTERN ]]
}

release_is_build_number() {
    local build="$1"
    [[ "$build" =~ ^[0-9]+$ ]]
}
