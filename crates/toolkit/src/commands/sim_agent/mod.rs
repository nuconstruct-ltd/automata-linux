mod routes;

use anyhow::Result;
use tracing::info;

pub fn run(port: u16) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async {
        let app = routes::router();
        let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
        info!(%addr, "sim-agent listening");

        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, app).await?;
        Ok(())
    })
}
