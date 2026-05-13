export default function StatusLog({ logs }) {
  return (
    <div className="section">
      <h2>Status Log</h2>
      <div className="log-container">
        {logs.length === 0 && <div className="log-entry info">Connect wallet to begin.</div>}
        {logs.map((log, i) => (
          <div key={i} className={`log-entry ${log.type}`}>
            <span className="log-time">{log.timestamp.split('T')[1]?.split('.')[0] || log.timestamp}</span>
            <span className="log-phase">[{log.phase}]</span>
            <span className="log-msg">{log.message}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
