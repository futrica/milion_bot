FROM ruby:4.0.1-slim

# Install docker CLI so self_improve.rb can restart sibling containers
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      ca-certificates \
      gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile ./
RUN bundle install --without development test

COPY . .

CMD ["ruby", "src/market_scanner.rb"]
