# Data Sources

## Basketball-Reference / Sports Reference LLC

All NBA data retrieved by the BR scraper originates from [Basketball-Reference.com](https://www.basketball-reference.com), operated by Sports Reference LLC.

Sports Reference's data-sharing policy explicitly permits reuse:

> "sharing, using, modifying, repackaging, or publishing data found on individual SRL webpages is welcomed for commercial or non-commercial purposes"

Full policy: https://www.sports-reference.com/sharing.html

**Attribution:** All data retrieved from Basketball-Reference is attributed to Basketball-Reference.com in any modeler-facing surface (query results, schema comments, UI labels).

**Crawl policy:** The scraper respects the 3-second crawl-delay specified in Basketball-Reference's `robots.txt`. No endpoint is hit more than once per 3 seconds.

## JB_HISTORIC_NBA (Snowflake seed)

Historical data for the 1946–2023 period is seeded from `JB_HISTORIC_NBA.PUBLIC`, a Snowflake database on the modeler team account containing data originally sourced from the NBA Stats API. This seed is a one-time operation; ongoing data comes from Basketball-Reference.

NBA.com data is explicitly **not** scraped by this pipeline. NBA.com Terms of Service Section 9.vii prohibits creation of databases of regularly updated statistics from their site.
