# random-tlder

Swift program that:

1. Fetches a random word from `random-word-api.herokuapp.com`
2. Picks a random TLD from Cloudflare's TLD list
3. Combines them into `{random-word}.{random-tld}`
4. Checks availability using the Cloudflare Registrar API
5. Prints the domain and registration cost if available
6. Retries until it finds an available domain

…don't judge my code pls i wrote it to procrastinate xx

needs `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` to work, just uses the api to check domain availablilty

## example output

```
Trying word 1: countercultural
{"registration_cost":"$27.70","domain":"countercultural.site"}
```
