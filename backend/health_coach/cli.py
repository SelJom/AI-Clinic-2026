from __future__ import annotations

import argparse
import json
from datetime import date, timedelta

from . import config, storage
from .coach import CoachAgent
from .escalation import build_escalation_summary
from .ingestion import PatientProfile, generate_synthetic_history
from .llm_backends import get_default_backend
from .pipeline import process_samples


def cmd_demo(args: argparse.Namespace) -> None:
    if args.reset and config.DB_PATH.exists():
        config.DB_PATH.unlink()
    storage.init_db()

    patient_id = args.patient_id
    profile = PatientProfile(patient_id=patient_id)
    start_day = date.today() - timedelta(days=args.days - 1)

    anomaly_days = {args.days - 2: args.anomaly} if args.anomaly != "none" else {}
    samples = generate_synthetic_history(profile, start_day, args.days, seed=args.seed, anomaly_days=anomaly_days)

    print(f"Seeding {args.days} synthetic days for patient '{patient_id}' "
          f"(anomaly={args.anomaly or 'none'} on day {args.days - 1})...\n")
    results = process_samples(patient_id, samples)

    print(f"{'Day':<12} {'RHR':>6} {'Sleep(h)':>9} {'Steps':>7} {'Risk':>10}")
    for r in results:
        f = r.features
        print(
            f"{f.day} "
            f"{f.resting_hr or 0:>6.1f} "
            f"{f.sleep_hours or 0:>9.1f} "
            f"{f.steps or 0:>7d} "
            f"{r.assessment.level.value:>10}"
        )

    last = results[-1]
    print(f"\n--- Recommendations for {last.features.day} ---")
    for rec in last.recommendations:
        print(f"\n[{'ESCALATE' if rec.escalate else 'info'}] {rec.title}")
        print(rec.body)
        for c in rec.citations:
            print(f"  cite [{c.evidence_level},{c.recommendation_grade}]: {c.text[:160]}...")

    if last.assessment.escalate:
        summary = build_escalation_summary(patient_id)
        print("\n--- Escalation summary (what the patient could show their care team) ---")
        print(summary.to_text())

    backend = get_default_backend()
    print(f"\nConversation backend: {backend.name}")
    if args.chat:
        agent = CoachAgent(backend=backend)
        print("Type a message (or 'exit'):")
        while True:
            try:
                msg = input("you> ").strip()
            except EOFError:
                break
            if msg.lower() in ("exit", "quit"):
                break
            if not msg:
                continue
            reply = agent.handle_message(patient_id, msg, last.assessment, last.recommendations)
            print(f"coach> {reply}\n")


def cmd_delete_patient(args: argparse.Namespace) -> None:
    storage.init_db()
    if not args.yes:
        confirm = input(
            f"This will permanently delete ALL local data for patient "
            f"'{args.patient_id}'. Type the patient id to confirm: "
        )
        if confirm != args.patient_id:
            raise SystemExit("Confirmation did not match - nothing deleted.")
    counts = storage.delete_patient_data(args.patient_id)
    total = sum(counts.values())
    print(f"Deleted {total} rows for patient '{args.patient_id}':")
    for table, n in counts.items():
        print(f"  {table}: {n}")


def cmd_export_patient(args: argparse.Namespace) -> None:
    storage.init_db()
    data = storage.export_patient_data(args.patient_id)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, default=str)
        print(f"Wrote export for '{args.patient_id}' to {args.out}")
    else:
        print(json.dumps(data, indent=2, default=str))


def cmd_serve(args: argparse.Namespace) -> None:
    try:
        import uvicorn
    except ImportError:
        raise SystemExit(
            "fastapi/uvicorn are not installed. Run: pip install -r backend/requirements.txt"
        )
    from .api import app

    storage.init_db()
    uvicorn.run(app, host=config.API_HOST, port=config.API_PORT)


def main() -> None:
    parser = argparse.ArgumentParser(prog="health_coach")
    sub = parser.add_subparsers(dest="command", required=True)

    demo = sub.add_parser("demo", help="Seed synthetic wearable data and run the full pipeline locally.")
    demo.add_argument("--patient-id", default="demo-patient")
    demo.add_argument("--days", type=int, default=21)
    demo.add_argument("--seed", type=int, default=42)
    demo.add_argument(
        "--anomaly", choices=["none", "tachycardia", "sleep_collapse", "inactivity"], default="tachycardia"
    )
    demo.add_argument("--reset", action="store_true", help="Wipe the local demo database first.")
    demo.add_argument("--no-chat", dest="chat", action="store_false", help="Skip the interactive chat loop.")
    demo.set_defaults(func=cmd_demo, chat=True)

    serve = sub.add_parser("serve", help="Run the local-only FastAPI bridge on 127.0.0.1.")
    serve.set_defaults(func=cmd_serve)

    delete_patient = sub.add_parser(
        "delete-patient", help="Right-to-erasure: permanently delete all local data for a patient."
    )
    delete_patient.add_argument("patient_id")
    delete_patient.add_argument("--yes", action="store_true", help="Skip the confirmation prompt.")
    delete_patient.set_defaults(func=cmd_delete_patient)

    export_patient = sub.add_parser(
        "export-patient", help="Right-to-access: dump all local data for a patient as JSON."
    )
    export_patient.add_argument("patient_id")
    export_patient.add_argument("--out", help="Write to this file instead of stdout.")
    export_patient.set_defaults(func=cmd_export_patient)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
