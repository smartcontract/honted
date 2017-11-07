defmodule HonteD do
  @type address :: String.t
  @type signature :: String.t
  @type nonce :: non_neg_integer  
  @type block_hash :: String.t # NOTE: this is a hash external to our APP i.e. consensus engine based, e.g. TM block has
end
