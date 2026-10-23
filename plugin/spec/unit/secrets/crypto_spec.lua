local crypto = require('crier_obs.secrets.chacha20poly1305')
local b64 = require('crier_obs.secrets.base64')
local function binary(hex) return (hex:gsub('%s', ''):gsub('..', function(v) return string.char(tonumber(v, 16)) end)) end
local function hex(data) return (data:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
describe('credential cryptography', function()
  it('matches RFC 8439 ChaCha20 block and Poly1305 vectors', function()
    local key = binary('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
    local block = crypto.block(key, 1, binary('000000090000004a00000000'))
    assert.equal('10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e' ..
      'd2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e', hex(block))
    local mac = crypto.poly1305('Cryptographic Forum Research Group',
       binary('85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b'))
    assert.equal('a8061dc1305136c6c22b8baf0c0127a9', hex(mac))
  end)
  it('matches the RFC 8439 AEAD vector and rejects tampering and wrong AAD', function()
    local key = binary('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f')
    local nonce, aad = binary('070000004041424344454647'), binary('50515253c0c1c2c3c4c5c6c7')
    local plain = 'Ladies and Gentlemen of the class of \'99: If I could offer you only one tip for the future, sunscreen would be it.'
    local ct, tag = crypto.encrypt(key, nonce, plain, aad)
    assert.equal('d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6' ..
      '3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36' ..
      '92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3' ..
      'ff4def08e4b7a9de576d26586cec64b6116', hex(ct))
    assert.equal('1ae10b594f09e26a7e902ecbd0600691', hex(tag))
    assert.equal(plain, crypto.decrypt(key, nonce, ct, tag, aad))
    assert.is_nil(crypto.decrypt(key, nonce, 'x' .. ct:sub(2), tag, aad))
    assert.is_nil(crypto.decrypt(key, nonce, ct, tag, 'wrong'))
    assert.is_nil(crypto.decrypt(key, nonce, ct, tag:sub(2), aad))
  end)
  it('reduces Poly1305 modulo 2^130-5 and rejects invalid key sizes', function()
    local mac = crypto.poly1305(string.rep('\255', 16), '\2' .. string.rep('\0', 31))
    assert.equal('03' .. string.rep('00', 15), hex(mac))
    assert.is_nil(crypto.poly1305('text', 'short'))
    assert.is_nil(crypto.block('short', 0, string.rep('\0', 12)))
    assert.is_nil(crypto.encrypt('short', string.rep('\0', 12), 'text'))
    local ct, tag = crypto.encrypt(string.rep('\0', 32), string.rep('\0', 12), '')
    assert.equal('', crypto.decrypt(string.rep('\0', 32), string.rep('\0', 12), ct, tag))
  end)
  it('round trips base64 and refuses malformed encodings', function()
    for _, value in ipairs({'', 'f', 'fo', 'foo', '\0\255😀'}) do assert.equal(value, b64.decode(b64.encode(value))) end
    for _, value in ipairs({'===a', 'a===', 'a b=', 'Zm=8', 'Zh==', 'Zg=A'}) do assert.is_nil(b64.decode(value)) end
  end)
end)
