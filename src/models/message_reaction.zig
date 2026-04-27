const Emoji = @import("emoji.zig").Emoji;

pub const MessageReaction = struct {
    count: u32 = 0,
    me: bool = false,
    emoji: Emoji,
};

test "MessageReaction stores count and emoji" {
    const reaction = MessageReaction{
        .count = 2,
        .emoji = .{ .name = "\u{1F44D}" },
    };

    try @import("std").testing.expectEqual(@as(u32, 2), reaction.count);
}
