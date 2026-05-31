#!/usr/bin/env bats
# sanitize_name: workspace/branch name -> a valid DNS label
# (lowercase; '/' -> '-'; drop chars outside [a-z0-9-]; <=63 chars).

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/dev-ip-lib.sh"
}

@test "sanitize_name lowercases and turns slashes into hyphens" {
  run sanitize_name "Feature/Foo"
  [ "$status" -eq 0 ]
  [ "$output" = "feature-foo" ]
}

@test "sanitize_name collapses runs of non-alphanumerics to a single hyphen" {
  run sanitize_name "my_branch"
  [ "$output" = "my-branch" ]
}

@test "sanitize_name treats spaces and punctuation as separators" {
  run sanitize_name "Foo Bar!!"
  [ "$output" = "foo-bar" ]
}

@test "sanitize_name trims leading and trailing hyphens" {
  run sanitize_name "--weird--"
  [ "$output" = "weird" ]
}

@test "sanitize_name truncates to 63 chars with no trailing hyphen" {
  run sanitize_name "$(printf 'a%.0s' {1..80})"
  [ "${#output}" -eq 63 ]
  [ "${output: -1}" != "-" ]
}
