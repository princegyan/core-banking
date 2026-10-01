import { IsBoolean } from 'class-validator';

export class UpdateUserDto {
  @IsBoolean()
  isActive: boolean;
}
