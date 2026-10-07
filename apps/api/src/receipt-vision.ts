import { Buffer } from "node:buffer";
import type { ExpenseCategory, ParsedReceipt, ReceiptVisionParser } from "./types.ts";
import { ApiError, expenseCategories } from "./types.ts";

export interface ReceiptVisionParserOptions {
  apiKey?: string;
  fetchFn?: typeof fetch;
  model?: string;
}

const receiptJsonSchema = {
  name: "receipt_extraction",
  strict: true,
  schema: {
    type: "object",
    properties: {
      merchant: { type: "string", description: "Printed store or merchant name, or empty string if not found." },
      category: {
        type: "string",
        enum: ["groceries", "restaurant", "movie", "concert", "other"],
        description: "Category of the purchase. Use 'other' if none match.",
      },
      expenseName: { type: "string", description: "Concise 2 to 5 word description for the expense, or empty string." },
      transactionDate: { type: "string", description: "Purchase date as YYYY-MM-DD if printed on receipt, or empty string." },
      items: {
        type: "array",
        description: "Itemized list of products or services purchased.",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "Item description." },
            cents: { type: "integer", description: "Price in integer cents (e.g. 1099 for $10.99)." },
          },
          required: ["name", "cents"],
          additionalProperties: false,
        },
      },
      taxCents: { type: "integer", description: "Sales tax in cents, or 0 if none." },
      tipCents: { type: "integer", description: "Tip or gratuity in cents, or 0 if none." },
      discountCents: { type: "integer", description: "General receipt discount in cents, or 0 if none." },
      totalCents: { type: "integer", description: "Final total printed on receipt in cents, or 0 if not found." },
      recognizedText: { type: "string", description: "Transcribed lines of text from the receipt." },
    },
    required: [
      "merchant",
      "category",
      "expenseName",
      "transactionDate",
      "items",
      "taxCents",
      "tipCents",
      "discountCents",
      "totalCents",
      "recognizedText",
    ],
    additionalProperties: false,
  },
};

interface OpenAiExtractionResult {
  merchant?: string;
  category?: string;
  expenseName?: string;
  transactionDate?: string;
  items?: Array<{ name?: string; cents?: number }>;
  taxCents?: number;
  tipCents?: number;
  discountCents?: number;
  totalCents?: number;
  recognizedText?: string;
}

export function createOpenAIReceiptParser(options: ReceiptVisionParserOptions = {}): ReceiptVisionParser {
  const model = options.model ?? "gpt-4o-mini";
  const fetchFn = options.fetchFn ?? globalThis.fetch;

  return {
    async parseReceipt(contentType: string, bytes: Uint8Array): Promise<ParsedReceipt> {
      const apiKey = options.apiKey
        ?? (typeof process !== "undefined" ? (process.env?.OPENAI_API_KEY ?? process.env?.["OpenAI API Key"]) : undefined)
        ?? (typeof (globalThis as unknown as { Deno?: { env: { get: (k: string) => string | undefined } } }).Deno !== "undefined"
          ? ((globalThis as unknown as { Deno: { env: { get: (k: string) => string | undefined } } }).Deno.env.get("OPENAI_API_KEY")
             ?? (globalThis as unknown as { Deno: { env: { get: (k: string) => string | undefined } } }).Deno.env.get("OpenAI API Key"))
          : undefined);

      if (!apiKey) {
        throw new ApiError(503, "OpenAI API key is not configured", "service_unavailable");
      }

      const base64 = Buffer.from(bytes).toString("base64");
      const dataUri = `data:${contentType};base64,${base64}`;

      const response = await fetchFn("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify({
          model,
          messages: [
            {
              role: "system",
              content: "You are an expert receipt reader. Extract itemized purchases, taxes, tips, discounts, totals, and metadata from receipt images. If information is missing or uncertain, use empty string, 0, or 'other'. Never invent items or amounts.",
            },
            {
              role: "user",
              content: [
                {
                  type: "text",
                  text: "Extract all purchased items with prices in cents, tax, tip, discount, final total, merchant name, category, and date.",
                },
                {
                  type: "image_url",
                  image_url: {
                    url: dataUri,
                    detail: "high",
                  },
                },
              ],
            },
          ],
          response_format: {
            type: "json_schema",
            json_schema: receiptJsonSchema,
          },
        }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new ApiError(502, `OpenAI vision request failed (${response.status}): ${errorText}`, "upstream_error");
      }

      const body = await response.json() as {
        choices?: Array<{ message?: { content?: string } }>;
      };

      const rawContent = body.choices?.[0]?.message?.content;
      if (!rawContent) {
        throw new ApiError(502, "OpenAI vision response did not include content", "upstream_error");
      }

      let parsed: OpenAiExtractionResult;
      try {
        parsed = JSON.parse(rawContent) as OpenAiExtractionResult;
      } catch {
        throw new ApiError(502, "OpenAI vision response was not valid JSON", "upstream_error");
      }

      const merchant = parsed.merchant?.trim() || null;
      const category: ExpenseCategory | null = (expenseCategories as readonly string[]).includes(parsed.category ?? "")
        ? (parsed.category as ExpenseCategory)
        : null;
      const expenseName = parsed.expenseName?.trim() || null;
      const transactionDate = parsed.transactionDate && /^\d{4}-\d{2}-\d{2}$/.test(parsed.transactionDate)
        ? parsed.transactionDate
        : null;

      const items = (parsed.items ?? [])
        .map((item) => ({
          name: (item.name ?? "").trim(),
          cents: Number.isSafeInteger(item.cents) ? Math.max(0, item.cents!) : 0,
        }))
        .filter((item) => item.name.length > 0 && item.cents >= 0);

      const taxCents = Number.isSafeInteger(parsed.taxCents) ? Math.max(0, parsed.taxCents!) : 0;
      const tipCents = Number.isSafeInteger(parsed.tipCents) ? Math.max(0, parsed.tipCents!) : 0;
      const discountCents = Number.isSafeInteger(parsed.discountCents) ? Math.max(0, parsed.discountCents!) : 0;
      const totalCents = Number.isSafeInteger(parsed.totalCents) && (parsed.totalCents ?? 0) > 0
        ? parsed.totalCents!
        : null;
      const recognizedText = parsed.recognizedText?.trim() || "";

      return {
        merchant,
        category,
        expenseName,
        transactionDate,
        items,
        taxCents,
        tipCents,
        discountCents,
        totalCents,
        recognizedText,
      };
    },
  };
}
