// Package accountclient calls the account service REST API.
package accountclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/shopspring/decimal"

	"github.com/artivisi/training-microservices-2026-01/studi-kasus/transfer/internal/transfer"
)

type Client struct {
	baseURL string
	http    *http.Client
}

// New uses an http.Client without a timeout: a slow account service makes every
// transfer wait as long as it takes.
func New(baseURL string) *Client {
	return &Client{baseURL: baseURL, http: &http.Client{}}
}

func (c *Client) Debit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "debit", amount, reference)
}

func (c *Client) Credit(ctx context.Context, number string, amount decimal.Decimal, reference string) error {
	return c.mutate(ctx, number, "credit", amount, reference)
}

func (c *Client) mutate(ctx context.Context, number, kind string, amount decimal.Decimal, reference string) error {
	body, err := json.Marshal(map[string]any{"amount": amount, "reference": reference})
	if err != nil {
		return err
	}
	url := fmt.Sprintf("%s/accounts/%s/%s", c.baseURL, number, kind)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", kind, number, err)
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch resp.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusNotFound:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrAccountNotFound)
	case http.StatusUnprocessableEntity:
		return fmt.Errorf("%s %s: %w", kind, number, transfer.ErrInsufficientFunds)
	default:
		return fmt.Errorf("%s %s: account service answered %s: %s", kind, number, resp.Status, bytes.TrimSpace(msg))
	}
}
