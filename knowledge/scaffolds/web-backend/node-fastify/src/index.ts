import Fastify from "fastify";
import cors from "@fastify/cors";
import routes from "./routes";

const fastify = Fastify({
  logger: true,
});

async function start() {
  await fastify.register(cors, {
    origin: true,
  });

  fastify.get("/health", async () => {
    return { status: "ok", timestamp: new Date().toISOString() };
  });

  await fastify.register(routes, { prefix: "/api" });

  const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 3000;
  const host = process.env.HOST || "0.0.0.0";

  try {
    await fastify.listen({ port, host });
  } catch (err) {
    fastify.log.error(err);
    process.exit(1);
  }
}

start();
