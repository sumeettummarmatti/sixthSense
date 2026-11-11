import CampusMap from "@/components/CampusMap";

import styles from "./page.module.css";

const LABELS = [
  { text: "Strong evidence of concern", color: "var(--evidence-strong)" },
  { text: "Some reports of concern", color: "var(--evidence-some)" },
  { text: "Insufficient data", color: "var(--evidence-insufficient)" },
];

export default function Home() {
  return (
    <main className={styles.main}>
      <aside className={styles.panel}>
        <h1 className={styles.title}>SixthSense</h1>
        <p className={styles.tagline}>Campus safety dashboard</p>
        <h2 className={styles.heading}>Published clusters</h2>
        <p className={styles.muted}>
          None yet. Clusters appear here once they reach 5 reports from 3 different devices.
        </p>
        <h2 className={styles.heading}>Evidence labels</h2>
        <ul className={styles.labels}>
          {LABELS.map((label) => (
            <li key={label.text}>
              <span className={styles.dot} style={{ background: label.color }} />
              {label.text}
            </li>
          ))}
        </ul>
      </aside>
      <section className={styles.map}>
        <CampusMap />
      </section>
    </main>
  );
}
