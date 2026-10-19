package transfer

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// transfersTotal counts saga outcomes by end state (Lab 8). The HTTP metrics
// show requests; this one shows money: a rising COMPENSATED or FAILED rate is a
// business incident even when every request answers fast.
var transfersTotal = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "transfers_total",
	Help: "Transfers that reached an end state, by status.",
}, []string{"status"})

// Every status starts at 0. A series that first appears with the value 5 shows
// no increase to rate(): the first transfers after a start would be missing
// from the dashboard.
func init() {
	for _, s := range []Status{Completed, Failed, Compensated, CompensationFailed} {
		transfersTotal.WithLabelValues(string(s))
	}
}
