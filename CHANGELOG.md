# Changelog

## v1.5.0

- Bump to Terraform v1.0.6 internally (only affects `fmt`)
- Fix Terraform v1 `plan` output truncation

## v1.4.0

- Bump to Terraform v0.15.0 internally (only affects `fmt`)
- Change the way `plan`s are truncated after introduction of new horizontal break in TF v0.15.0
- Add `validate` comment handling
- Update readme

## v1.3.0

- Bump to Terraform v0.14.9 internally (only affects `fmt`)
- Fix output truncation in Terraform v0.14 and above

## v1.2.0

- Bump to Terraform v0.14.5 internally (only affects `fmt`)
- Change to leave `fmt` output as-is
- Add colourisation to `plan` diffs where there are changes (on by default, controlled with `HIGHLIGHT_CHANGES` environment variable)
- Update readme

## v1.1.0

- Adds better parsing for Terraform v0.14

## v1.0.0

- Initial release.
