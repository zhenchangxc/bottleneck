local process_tick = function (now, always_publish)

  local compute_capacity = function (maxConcurrent, running, reservoir)
    if maxConcurrent ~= nil and reservoir ~= nil then
      return math.min((maxConcurrent - running), reservoir)
    elseif maxConcurrent ~= nil then
      return maxConcurrent - running
    elseif reservoir ~= nil then
      return reservoir
    else
      return nil
    end
  end

  local settings = redis.call('hmget', settings_key,
    'id',
    'maxConcurrent',
    'running',
    'reservoir',
    'reservoirRefreshInterval',
    'reservoirRefreshAmount',
    'lastReservoirRefresh'
  )
  local id = settings[1]
  local maxConcurrent = tonumber(settings[2])
  local running = tonumber(settings[3])
  local reservoir = tonumber(settings[4])
  local reservoirRefreshInterval = tonumber(settings[5])
  local reservoirRefreshAmount = tonumber(settings[6])
  local lastReservoirRefresh = tonumber(settings[7])

  local initial_capacity = compute_capacity(maxConcurrent, running, reservoir)

  --
  -- Process 'running' changes
  --
  local expired = redis.call('zrangebyscore', job_expirations_key, '-inf', '('..now)

  if #expired > 0 then
    redis.call('zremrangebyscore', job_expirations_key, '-inf', '('..now)

    local flush_batch = function (batch, acc)
      local weights = redis.call('hmget', job_weights_key, unpack(batch))
                      redis.call('hdel',  job_weights_key, unpack(batch))
      local clients = redis.call('hmget', job_clients_key, unpack(batch))
                      redis.call('hdel',  job_clients_key, unpack(batch))

      -- Calculate sum of removed weights
      for i = 1, #weights do
        acc['total'] = acc['total'] + (tonumber(weights[i]) or 0)
      end

      -- Calculate sum of removed weights by client
      local client_weights = {}
      for i = 1, #clients do
        if weights[i] ~= nil then
          acc['client_weights'][clients[i]] = (acc['client_weights'][clients[i]] or 0) + tonumber(weights[i])
        end
      end
    end

    local acc = {
      ['total'] = 0,
      ['client_weights'] = {}
    }
    local batch_size = 1000

    -- Compute changes to Zsets and apply changes to Hashes
    for i = 1, #expired, batch_size do
      local batch = {}
      for j = i, math.min(i + batch_size - 1, #expired) do
        table.insert(batch, expired[j])
      end

      flush_batch(batch, acc)
    end

    -- Apply changes to Zsets
    if acc['total'] > 0 then
      redis.call('hincrby', settings_key, 'done', acc['total'])
      running = tonumber(redis.call('hincrby', settings_key, 'running', -acc['total']))
    end

    for client, weight in pairs(acc['client_weights']) do
      redis.call('zincrby', client_running_key, -weight, client)
    end
  end

  --
  -- Process 'reservoir' changes
  --
  local reservoirRefreshActive = reservoirRefreshInterval ~= nil and reservoirRefreshAmount ~= nil
  if reservoirRefreshActive and now >= lastReservoirRefresh + reservoirRefreshInterval then
    reservoir = reservoirRefreshAmount
    redis.call('hmset', settings_key,
      'reservoir', reservoir,
      'lastReservoirRefresh', now
    )
  end

  --
  -- Broadcast capacity changes
  --
  local final_capacity = compute_capacity(maxConcurrent, running, reservoir)

  if always_publish or (initial_capacity ~= nil and final_capacity == nil) then
    -- always_publish or was not unlimited, now unlimited
    redis.call('publish', 'b_'..id, 'capacity:'..(final_capacity or ''))

  elseif initial_capacity ~= nil and final_capacity ~= nil and final_capacity > initial_capacity then
    -- capacity was increased
    -- send the capacity message to the limiter having the lowest number of running jobs
    -- the tiebreaker is the limiter having not registered a job in the longest time

    local lowest_concurrency_value = nil
    local lowest_concurrency_clients = {}
    local lowest_concurrency_last_registered = {}
    local client_concurrencies = redis.call('zrange', client_running_key, 0, -1, 'withscores')

    for i = 1, #client_concurrencies, 2 do
      local client = client_concurrencies[i]
      local concurrency = tonumber(client_concurrencies[i+1])

      if (
        lowest_concurrency_value == nil or lowest_concurrency_value == concurrency
      ) and (
        tonumber(redis.call('hget', client_num_queued_key, client)) > 0
      ) and (
        tonumber(redis.call('pubsub', 'numsub', 'b_'..id..'_'..client)[2]) > 0
      ) then
        lowest_concurrency_value = concurrency
        table.insert(lowest_concurrency_clients, client)
        local last_registered = tonumber(redis.call('zscore', client_last_registered_key, client))
        table.insert(lowest_concurrency_last_registered, last_registered)
      end
    end

    if #lowest_concurrency_clients > 0 then
      local position = 1
      local earliest = lowest_concurrency_last_registered[1]

      for i,v in ipairs(lowest_concurrency_last_registered) do
        if v < earliest then
          position = i
          earliest = v
        end
      end

      local next_client = lowest_concurrency_clients[position]
      redis.call('publish', 'b_'..id..'_'..next_client, 'capacity:'..(final_capacity or ''))
    else
      redis.call('publish', 'b_'..id, 'capacity:'..(final_capacity or ''))
    end

  end

  return {final_capacity, running, reservoir}
end