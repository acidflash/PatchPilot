#!/usr/bin/env bash
set -euo pipefail

# Run from inside the patchpilot project directory:
#   cd patchpilot
#   bash patchpilot-add-delete-agents.sh
#   docker compose up -d --build

if [[ ! -f "backend/app/main.py" ]]; then
  echo "ERROR: Run this from inside the patchpilot project directory."
  exit 1
fi

if [[ ! -f "backend/app/templates/admin.html" ]]; then
  echo "ERROR: Missing backend/app/templates/admin.html"
  exit 1
fi

echo "[+] Patching backend delete route"

if grep -q "PATCHPILOT_DELETE_MACHINE_ROUTE" backend/app/main.py; then
  echo "[+] Delete route already exists"
else
  cat >> backend/app/main.py <<'PYEOF'


# PATCHPILOT_DELETE_MACHINE_ROUTE
@app.post("/admin/machines/{machine_pk}/delete")
def delete_machine(
    machine_pk: int,
    db: Session = Depends(get_db),
):
    machine = db.query(Machine).filter(Machine.id == machine_pk).first()
    if not machine:
        raise HTTPException(status_code=404, detail="Machine not found")

    db.query(Job).filter(Job.machine_id == machine.id).delete()
    db.delete(machine)
    db.commit()

    return RedirectResponse("/admin", status_code=303)
PYEOF
fi

echo "[+] Patching admin UI"

python3 - <<'PY'
from pathlib import Path

p = Path("backend/app/templates/admin.html")
txt = p.read_text()

if "/admin/machines/{{ m.id }}/delete" in txt:
    print("[+] Delete button already exists")
    raise SystemExit(0)

old = '''        <form method="post" action="/admin/machines/{{ m.id }}/jobs">
          <select name="action">
            <option value="check_updates">check</option>
            <option value="upgrade">upgrade</option>
            <option value="security_upgrade">security upgrade</option>
            <option value="reboot">reboot</option>
            <option value="apt_clean">apt clean</option>
          </select>
          <label><input type="checkbox" name="allow_reboot" value="true"> allow reboot</label>
          <button type="submit">queue</button>
        </form>
'''

new = '''        <form method="post" action="/admin/machines/{{ m.id }}/jobs" style="margin-bottom: 6px;">
          <select name="action">
            <option value="check_updates">check</option>
            <option value="upgrade">upgrade</option>
            <option value="security_upgrade">security upgrade</option>
            <option value="reboot">reboot</option>
            <option value="apt_clean">apt clean</option>
          </select>
          <label><input type="checkbox" name="allow_reboot" value="true"> allow reboot</label>
          <button type="submit">queue</button>
        </form>

        <form method="post" action="/admin/machines/{{ m.id }}/delete" onsubmit="return confirm('Delete agent {{ m.hostname }} and all its jobs?');">
          <button type="submit" style="background: #7f1d1d; color: #fff; border: 1px solid #991b1b;">delete agent</button>
        </form>
'''

if old not in txt:
    raise SystemExit("ERROR: Could not find the job form block in admin.html. Patch manually.")

p.write_text(txt.replace(old, new))
print("[+] Added delete button")
PY

echo
echo "[+] Done."
echo "Rebuild:"
echo "  docker compose up -d --build"
