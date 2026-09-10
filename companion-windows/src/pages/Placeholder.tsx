export default function Placeholder({ title, text }: { title: string; text: string }) {
  return (
    <section className="page">
      <header className="page-head">
        <h1>{title}</h1>
      </header>
      <p className="muted">{text}</p>
    </section>
  );
}
