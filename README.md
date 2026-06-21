# macOS Time Machine Backup Validator

A Bash toolkit for validating Time Machine configuration, destinations, snapshots, backup age, exclusions, and recent errors. It also includes a guarded repair mode for common service and automatic-backup problems.

## Checks performed

- Configured Time Machine destinations
- Latest backup and local snapshot dates
- Backup age against a configurable threshold
- Automatic-backup setting and current backup status
- Backup exclusions, APFS snapshots, free space, and recent `backupd` events
- Text, CSV, JSON, error, and repair-action logs

## Diagnostic usage

```bash
chmod +x src/time_machine_validator.sh
sudo ./src/time_machine_validator.sh --max-age-hours 48
```

## Repair usage

Preview the repairs without changing the Mac:

```bash
sudo ./src/time_machine_validator.sh --repair --dry-run
```

Apply guarded repairs and start an automatic backup:

```bash
sudo ./src/time_machine_validator.sh --repair --start-backup --yes
```

Repair mode can:

- Back up the current Time Machine preference plist when present
- Enable automatic Time Machine backups when disabled
- Restart the `backupd` service
- Optionally start an automatic backup
- Run post-repair verification and record every action

It does **not** delete, thin, inherit, erase, or reconfigure backup destinations or snapshots.

## Safety controls

- Repair mode requires root privileges
- `--dry-run` prints intended actions without changing the Mac
- A confirmation prompt is shown unless `--yes` is supplied
- Pre-repair evidence is stored in the report directory
- Failed repair actions are logged and return a non-zero exit code

## Exit codes

- `0` — healthy or successful repair
- `10` — attention still required or repair cancelled
- `20` — one or more repair actions failed
- `2` — invalid arguments
- `3` — wrong platform or insufficient privileges

## Requirements

- macOS 12 or later recommended
- Bash 3.2+
- Administrator privileges for complete evidence and all repair actions

## Validation note

The script has been statically reviewed for shell syntax and control flow. Runtime testing must be performed on a suitable macOS system before production use.

## Author

Dewald Pretorius — L2 IT Support Engineer
