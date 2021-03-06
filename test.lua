require 'torch'
require 'nn'
require 'nngraph'
require 'optim'
require 'lfs'
require 'cudnn'
require 'cunn'
require 'xlua'
require 'gnuplot'

require 'util.OneHot'
require 'util.misc'
local DataLoader = require 'util.DataLoader'
local model_utils = require 'util.model_utils'
local LSTM = require 'model.LSTM'

-- there is a better one called llap
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a character-level language model')
cmd:argument('-model','model checkpoint to use for sampling')
cmd:option('-seed',123,'random number generator\'s seed')
cmd:option('-gpuid',0,'which gpu to use. -1 = use CPU')
cmd:option('-data_dir','data/test_')
cmd:option('-batch_size',128)
cmd:option('-seq_length', 4)
cmd:option('-n_class', 10)
cmd:option('-nbatches', 500)
cmd:option('-overlap', 0)
cmd:option('-draw', 0)
cmd:text()

-- parse input params
opt = cmd:parse(arg)
torch.manualSeed(opt.seed)

opt.overlap = (opt.overlap == 1)
opt.draw = (opt.draw == 1)

checkpoint = torch.load(opt.model)
protos = checkpoint.protos

current_state = {}
for L = 1,checkpoint.opt.num_layers do
   -- c and h for all layers
   local h_init = torch.zeros(1, checkpoint.opt.rnn_size)
   if opt.gpuid >= 0 then h_init = h_init:cuda() end
   table.insert(current_state, h_init:clone())
   if checkpoint.opt.model == 'lstm' then
        table.insert(current_state, h_init:clone())
   end
end
 
if opt.gpuid >= 0 then
    for k,v in pairs(protos) do v:cuda() end
end


local split_sizes = {0.90,0.05,0.05}
loader = DataLoader.create(opt.data_dir, opt.batch_size, opt.seq_length, split_sizes, opt.n_class, opt.nbatches, opt.overlap)
n_data = loader.test_n_data
vocab_mapping = loader.vocab_mapping
vocab_size = loader.vocab_size
vocab = {}
for k, v in pairs(vocab_mapping) do
    vocab[v] = k
end

correct = 0.0
total = 0.0
local accuracy_for_each_class = torch.Tensor(opt.n_class):fill(0)
local n_data_for_each_class = accuracy_for_each_class:clone()
local accuracy_2 = 0.0 --accuracy_for_each_class:clone()
local accuracy_1 = 0.0 --accuracy_for_each_class:clone()
local accuracy_1_ = 0.0
local first_two = 0.0

protos.rnn:evaluate()

tmp_num = 0
tmp_val = 0.0

for i = 1, n_data do
    xlua.progress(i, n_data)
    local x, y = loader:next_test_data()
    
    --print("-----------Data----------")
    --print(x)
    --print(y)
    --[[
    ina = {'c', 'y', 'w', 'd', 'r', 'r', 'x', 'n', 'f', 'i', 'j'}
    x = torch.Tensor(#ina)
    for h = 1, #ina do
        x[h] = vocab_mapping[ina[h]
    end
    
    tmp_str = ""
    for z = 1, x:size(1) do
        tmp_str = tmp_str .. " " .. vocab[x[z]
    end
    print('------data------')
    print(tmp_str)
    print(y)
    --]]
    if opt.gpuid >= 0 then
        x = x:float():cuda()
    end
    
    draw1 = torch.Tensor(x:size(1)):fill(0)
    draw2 = torch.Tensor(x:size(1)):fill(0)

    local rnn_state = {[0] = current_state}
    local final_pred = torch.Tensor(opt.n_class):fill(0):cuda()
    for t = 1, x:size(1) do
        local x_OneHot = OneHot(vocab_size):forward(torch.Tensor{x[t]}):cuda()
        local lst = protos.rnn:forward{x_OneHot, unpack(rnn_state[t-1])}
        rnn_state[t] = {}
        for i = 1, #current_state do table.insert(rnn_state[t], lst[i]) end
        prediction = lst[#lst]
        tmp_num = tmp_num + 1
        tmp_val = tmp_val + prediction:sum()
        --print(prediction:sum())
        draw1[t] = prediction[{1, y[1]}]
        if opt.overlap then
            draw2[t] = prediction[{1, y[2]}]
        end
        tmp_str = vocab[x[t]] .. "\t"
        for m = 1, prediction:size(2) do
            tmp_str = tmp_str .. '  ' .. string.format("%.3f", prediction[{1, m}])
        end
        --print(tmp_str)
        -- Take average
        final_pred = final_pred + prediction
        --[[
        -- Take Maximum
        for w = 1, opt.n_class do
            final_pred[w] = math.max(final_pred[w], prediction[{1, w}])
        end
        --]]
    end
    if opt.draw then
        x_axis = torch.range(1, x:size(1))
        if not opt.overlap then
            gnuplot.pngfigure('./image_pureData/instance' .. tostring(i) .. '.png')
            gnuplot.plot({'class '..tostring(y[1]), x_axis, draw1, '-'})
        else
            gnuplot.pngfigure('./image/instance' .. tostring(i) .. '.png')
            gnuplot.plot({'class '..tostring(y[1]), x_axis, draw1, '-'}, {'class '..tostring(y[2]), x_axis, draw2, '-'})
        end
        x_str = 'set xtics ("'
        for mm = 1, x:size(1)-1 do
            x_str = x_str .. tostring(vocab[x[mm]]) .. '" ' .. tostring(mm) .. ', "'
        end
        x_str = x_str .. tostring(vocab[x[x:size(1)]]) .. '" ' .. tostring(x:size(1)) .. ') '
        gnuplot.raw(x_str)
        gnuplot.axis{'','',0,1}
        gnuplot.plotflush()
    end
    final_pred = final_pred/x:size(1)
    --print(final_pred)
    --io.read()
    tmp_str = "Total:\t"
    for m = 1, final_pred:size(1) do
        tmp_str = tmp_str .. "  " .. string.format("%.3f", final_pred[{m}])
    end
    --print(tmp_str)
    --io.read()
    --print(final_pred:sum())
    --io.read()
    --print(res_y)
    total = total + 1
    k_ = 0
    increasing_ind = torch.Tensor(opt.n_class):apply(function(increasing_ind)
        k_ = k_ + 1
        return k_
    end)
    if not opt.overlap then
        fail_list = {}
        fail_list_ind = 1
        y = y[1]
        _, res_rank = torch.sort(final_pred)
        res_y = res_rank[#res_rank]
        --[[
        print(x)
        print(y)
        print(final_pred)
        print(res_rank)
        --]]
        n_data_for_each_class[y] = n_data_for_each_class[y] + 1
        if y == res_y then
            correct = correct + 1
            accuracy_for_each_class[y] = accuracy_for_each_class[y] + 1
        else
            print(y .. ':' .. res_y)
        end
    else
        _, res_rank = torch.sort(final_pred)
        res_y1 = res_rank[-1]
        res_y2 = res_rank[-2]
        if res_y1 == y[1] or res_y1 == y[2] and res_y2 == y[1] or res_y2 == y[2] then
            first_two = first_two + 1
        end
        res_y = increasing_ind:maskedSelect(final_pred:gt(0.5):byte())
        res1 = (res_y:eq(y[1]):sum() >= 1)
        res2 = (res_y:eq(y[2]):sum() >= 1)
        --print(res1)
        --print(res2)
        if res1 and res2 then
            accuracy_1_ = accuracy_1_ + 1
            if #res_y == 2 then
                accuracy_2 = accuracy_2 + 1
                accuracy_1 = accuracy_1 + 1
            end
        else if res1 or res2 and #res_y == 2 then
            accuracy_1 = accuracy_1 + 1
        end
        end
    end
end

print("Look at this")
print(tmp_val / tmp_num)

if not opt.overlap then
    accuracy_for_each_class = torch.cdiv(accuracy_for_each_class, n_data_for_each_class)

    print("Accuracy for each class:")
    print(accuracy_for_each_class)

    print("Accuracy:")
    print(correct/total)
else 
    print("Accuracy of exact correct:")
    print(accuracy_2 / total)
    print("Accuracy of only one is correct or two are correct")
    print(accuracy_1 / total)
    print("Accracy as long as the result consists of the two classes")
    print(accuracy_1_ / total)
    print("Accuracy as first highest two are correct")
    print(first_two / total)
end
