# macOS Time Machine Backup Validator

A read-only Bash toolkit for validating Time Machine configuration, destinations, snapshots, backup age, exclusions, and recent backup errors.

## Checks performed

- Configured Time Machine destinations
- Latest backup and local snapshot dates
- Backup age against a configurable threshold
- Backup status, exclusions, and APFS snapshots
- Destination reachability and free space indicators
- Recent Time Machine and backupd log events
- Text, CSV, and JSON reports

## Usage

```bash
chmod +x src/time_machine_validator.sh
sudo ./src/time_machine_validator.sh --max-age-hours 48
```

## Safety

The script does not start, stop, delete, thin, inherit, or modify backups or snapshots.

## Requirements

- macOS 12 or later recommended
- Bash 3.2+
- Administrator privileges for complete evidence

## Author

Dewald Pretorius — L2 IT Support Engineer
