// Typed graph doubles compile the real update_pooling body; numerical SDK and GPU checks remain separate.
#include <algorithm>
#include <functional>
#include <iostream>
#include <memory>
#include <type_traits>
#include <vector>

namespace op {
enum class pooling_mode { max, average, lpnorm };
struct pooling { pooling_mode mode; std::vector<std::size_t> padding{0, 0, 0, 0}; };
struct pad { std::vector<std::size_t> pads{0, 0, 0, 0, 0, 0, 1, 1}; };
}
struct instruction;
using instruction_ref = std::shared_ptr<instruction>;
struct shape {
    std::vector<std::size_t> dimensions{1, 1, 3, 3};
    const auto& lens() const { return dimensions; }
};
struct operation {
    op::pooling pool{op::pooling_mode::max};
    op::pad pad;
};
struct instruction {
    shape dimensions;
    operation operation_value;
    std::vector<instruction_ref> parents;
    const auto& get_operator() const { return operation_value; }
    const auto& get_shape() const { return dimensions; }
    const auto& inputs() const { return parents; }
};
template<class T> T any_cast(const operation& value)
{
    if constexpr(std::is_same_v<T, op::pooling>) return value.pool;
    else return value.pad;
}
struct module {
    int replacements = 0;
    void replace_instruction(const instruction_ref& ins, const op::pooling& pool,
                             const std::vector<instruction_ref>& parents)
    {
        ++replacements;
        ins->operation_value.pool = pool;
        ins->parents = parents;
    }
};
#include "pooling.inc"

int main()
{
    for(auto mode : {op::pooling_mode::max, op::pooling_mode::average, op::pooling_mode::lpnorm})
    {
        auto image = std::make_shared<instruction>();
        auto pad = std::make_shared<instruction>();
        pad->parents = {image};
        auto pool = std::make_shared<instruction>();
        pool->operation_value.pool.mode = mode;
        pool->parents = {pad};
        struct module graph;
        update_pooling(pad, pool, graph);
        if(mode == op::pooling_mode::lpnorm)
        {
            if(graph.replacements != 1 or pool->parents.front() != image or
               pool->operation_value.pool.padding != std::vector<std::size_t>{0, 0, 1, 1})
            {
                std::cerr << "LP padding fold changed\n";
                return 1;
            }
        }
        else if(graph.replacements != 0 or pool->parents.front() != pad or
                pool->operation_value.pool.padding != std::vector<std::size_t>{0, 0, 0, 0})
        {
            std::cerr << (mode == op::pooling_mode::max ? "MAX" : "AVERAGE")
                      << " PAD MUST REMAIN EXPLICIT\n";
            return 1;
        }
    }
    std::cout << "MIGraphX pooling policy checks: 3\n";
}
