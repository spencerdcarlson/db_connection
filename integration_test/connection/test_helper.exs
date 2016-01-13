ExUnit.start([capture_log: true])

Code.require_file "../../test/test_support.exs", __DIR__

defmodule TestPool do
  use TestConnection, [pool: DBConnection.Connection, pool_size: 1]
end
