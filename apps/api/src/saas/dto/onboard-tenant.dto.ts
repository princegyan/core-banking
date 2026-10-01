import { IsNotEmpty, IsOptional, IsString, MaxLength } from 'class-validator';

export class OnboardTenantDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(150)
  name: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  slug: string;

  @IsString()
  @IsOptional()
  @MaxLength(2)
  countryCode?: string;

  @IsString()
  @IsOptional()
  @MaxLength(3)
  defaultCurrency?: string;

  @IsString()
  @IsNotEmpty()
  adminEmail: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  adminFirstName: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  adminLastName: string;

  @IsString()
  @IsOptional()
  planCode?: string;
}
