# OpenSpecimen Automated Installer

This repo contains a single Bash installer, [`install_openspecimen.sh`](/home/av/github/os_auto_installer/install_openspecimen.sh), that automates a fresh OpenSpecimen installation on Ubuntu with:

- OpenSpecimen build download and extraction
- Java 17 installation and Tomcat `setenv.sh` setup
- MySQL installation, re-initialization, and schema/user creation
- Tomcat `context.xml` wiring
- `openspecimen.properties` generation/update
- Running the bundled OpenSpecimen `install.sh`

## Run

```bash
sudo ./install_openspecimen.sh
```

You can also preseed values to reduce prompts:

```bash
sudo ./install_openspecimen.sh \
  --download-url "https://example.invalid/openspecimen.zip" \
  --download-user "my-user" \
  --download-password "my-pass" \
  --env DEV \
  --mysql-root-password "RootPasswordHere" \
  --mysql-app-password "AppPasswordHere"
```

The installer also saves your answers into a local `.env` file next to the script and reloads them automatically on the next run.

To discard the saved inputs and force a full fresh prompt cycle:

```bash
sudo ./install_openspecimen.sh --reset-env
```

## Important Notes

- This is designed for a fresh install on Ubuntu.
- Saved installer inputs are stored in `.env` with `600` permissions.
- If MySQL already exists with data, the script stops before wiping `/var/lib/mysql` unless `--force-mysql-reset` is supplied.
- The script assumes the OpenSpecimen zip contains the usual bundled installer and Tomcat payload.
- Installer logs are written to `/usr/local/openspecimen_installable/logs`.
