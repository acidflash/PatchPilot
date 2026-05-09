#!/usr/bin/env bash
set -euo pipefail

# PatchPilot schedule target dropdown UI fix
# Run:
#   cd patchpilot
#   bash patchpilot-schedule-target-dropdown.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/templates/admin.html" ]]; then
  echo "ERROR: Missing backend/app/templates/admin.html"
  echo "Run this from inside the patchpilot project directory."
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="_backup_schedule_dropdown_${TS}"

echo "[+] Creating backup: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
cp -a backend/app/templates "${BACKUP_DIR}/templates"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/templates/admin.html")
txt = p.read_text()

pattern = re.compile(
    r'<form\s+class="form-grid full"\s+method="post"\s+action="/admin/schedules">.*?</form>',
    re.DOTALL,
)

new_form = """<form class="form-grid full" method="post" action="/admin/schedules" id="schedule-form">
            <input name="name" placeholder="schedule name" required>

            <select name="target_type" id="schedule-target-type">
              <option value="machine">machine</option>
              <option value="group">group</option>
            </select>

            <select id="schedule-machine-target">
              {% for m in machines %}
                <option value="{{ m.id }}">{{ m.hostname }} | {{ m.machine_id }}</option>
              {% endfor %}
            </select>

            <select id="schedule-group-target" style="display:none;">
              {% for g in groups %}
                <option value="{{ g.id }}">{{ g.name }}</option>
              {% endfor %}
            </select>

            <input type="hidden" name="target_id" id="schedule-target-id">

            <select name="action">
              <option value="check_updates">check</option>
              <option value="upgrade">upgrade</option>
              <option value="security_upgrade">security upgrade</option>
              <option value="apt_clean">apt clean</option>
              <option value="self_update">update agent</option>
              <option value="reboot">reboot</option>
            </select>

            <select name="day_of_week">
              <option value="all">daily</option>
              <option value="mon">monday</option>
              <option value="tue">tuesday</option>
              <option value="wed">wednesday</option>
              <option value="thu">thursday</option>
              <option value="fri">friday</option>
              <option value="sat">saturday</option>
              <option value="sun">sunday</option>
            </select>

            <input name="time_of_day" value="03:00">
            <input name="timezone" value="Europe/Stockholm">

            <div>
              <label class="small"><input type="checkbox" name="allow_reboot" value="true"> reboot</label><br>
              <label class="small"><input type="checkbox" name="require_approval" value="true"> approval</label><br>
              <label class="small"><input type="checkbox" name="enabled" value="true" checked> enabled</label>
            </div>

            <div class="span muted small">
              Target väljs automatiskt från dropdown. Du behöver inte längre slå upp target ID manuellt.
            </div>

            <button class="primary span" type="submit">Create schedule</button>
          </form>"""

if not pattern.search(txt):
    raise SystemExit("Could not find schedule form. UI may be too customized. Manual patch needed.")

txt = pattern.sub(new_form, txt, count=1)

if "function patchpilotScheduleTargetSync" not in txt:
    js = """
<script>
  function patchpilotScheduleTargetSync() {
    const targetType = document.getElementById("schedule-target-type");
    const machineSelect = document.getElementById("schedule-machine-target");
    const groupSelect = document.getElementById("schedule-group-target");
    const targetId = document.getElementById("schedule-target-id");

    if (!targetType || !machineSelect || !groupSelect || !targetId) {
      return;
    }

    if (targetType.value === "group") {
      machineSelect.style.display = "none";
      groupSelect.style.display = "";
      groupSelect.disabled = false;
      machineSelect.disabled = true;
      targetId.value = groupSelect.value || "";
    } else {
      groupSelect.style.display = "none";
      machineSelect.style.display = "";
      machineSelect.disabled = false;
      groupSelect.disabled = true;
      targetId.value = machineSelect.value || "";
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    const targetType = document.getElementById("schedule-target-type");
    const machineSelect = document.getElementById("schedule-machine-target");
    const groupSelect = document.getElementById("schedule-group-target");
    const form = document.getElementById("schedule-form");

    if (targetType) targetType.addEventListener("change", patchpilotScheduleTargetSync);
    if (machineSelect) machineSelect.addEventListener("change", patchpilotScheduleTargetSync);
    if (groupSelect) groupSelect.addEventListener("change", patchpilotScheduleTargetSync);

    if (form) {
      form.addEventListener("submit", function (event) {
        patchpilotScheduleTargetSync();
        const targetId = document.getElementById("schedule-target-id");
        if (!targetId || !targetId.value) {
          event.preventDefault();
          alert("No target selected. Create at least one machine or group first.");
        }
      });
    }

    patchpilotScheduleTargetSync();
  });
</script>
"""
    txt = txt.replace("</body>", js + "\n</body>")

p.write_text(txt)
PY

echo
echo "[+] Schedule dropdown patch installed."
echo "Backup saved in: ${BACKUP_DIR}"
echo
echo "Rebuild:"
echo "  docker compose up -d --build"
