import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import crypto from "crypto";

const ddbClient = new DynamoDBClient();

const CORS = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "*",
  "Access-Control-Allow-Methods": "*",
};

export const handler = async (event) => {
  console.log("Received event:", JSON.stringify(event));

  try {
    const body =
      typeof event.body === "string" ? JSON.parse(event.body) : event.body || {};

    const { customerName, amount, product, notes } = body;

    if (!customerName || !amount || !product) {
      return {
        statusCode: 400,
        headers: CORS,
        body: JSON.stringify({
          message: "customerName, amount, and product are required.",
        }),
      };
    }

    const orderId = crypto.randomUUID();
    const createdAt = new Date().toISOString();

    await ddbClient.send(
      new PutItemCommand({
        TableName: process.env.ORDERS_TABLE_NAME,
        Item: {
          orderId: { S: orderId },
          customerName: { S: customerName },
          amount: { N: String(amount) },
          product: { S: product },
          notes: { S: notes || "" },
          status: { S: "PENDING" },
          createdAt: { S: createdAt },
          // TTL. This runs as a public demo, so every order self-deletes after
          // 24h and the table cannot grow without bound. DynamoDB expects epoch
          // SECONDS as a Number — passing milliseconds means "year 56000" and
          // nothing is ever deleted, silently.
          expiresAt: { N: String(Math.floor(Date.now() / 1000) + 86400) },
        },
      })
    );

    return {
      statusCode: 201,
      headers: CORS,
      body: JSON.stringify({
        message: "Order created successfully",
        orderId,
        status: "PENDING",
      }),
    };
  } catch (error) {
    console.error("Error creating order:", error);
    return {
      statusCode: 500,
      headers: CORS,
      body: JSON.stringify({ message: "Internal server error" }),
    };
  }
};
